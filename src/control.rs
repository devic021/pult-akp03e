//! The control socket the app talks to.
//!
//! Only one process can hold the dock's HID interface, and that process is the
//! daemon. So the app never touches the device: it asks over a Unix socket in
//! the user's own Application Support directory, and the daemon answers.
//!
//! The wire format is one JSON object per line in each direction. A client
//! either asks a question and gets one answer, or subscribes and is then sent
//! events until it goes away.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::Config;

/// How long a client waits for the daemon to answer before giving up. The
/// daemon checks for calls every loop, so this only trips if it is wedged.
const REPLY_TIMEOUT: Duration = Duration::from_secs(5);

/// What the app can ask for.
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Request {
    /// Device, scene, page, frontmost app, permission state.
    Status,
    /// The whole configuration, as JSON.
    Config,
    /// Replace the configuration and write it to disk.
    SetConfig { config: Box<Config> },
    /// Names of every bundled icon.
    Icons,
    /// One icon, rendered to a PNG.
    Icon {
        name: String,
        size: Option<u32>,
        color: Option<String>,
    },
    /// One key, rendered from values the app has not saved yet, so the editor
    /// can show exactly what the dock would show while you are still typing.
    RenderKey {
        key: Box<crate::config::Key>,
        size: Option<u32>,
        pages: Option<(usize, usize)>,
    },
    /// A scene's page, rendered exactly as the dock would show it.
    Preview {
        scene: String,
        #[serde(default)]
        page: usize,
    },
    /// Set the backlight now, without saving it.
    Brightness { value: u8 },
    /// Show a scene.
    Scene { name: String },
    /// Show a page of the current scene.
    Page { value: usize },
    /// Write a boot logo into the device, which is the one thing it keeps.
    BootLogo { path: String },
    /// Blank the dock, or wake it.
    Sleep,
    Wake,
    /// Stop answering and start receiving events instead.
    Subscribe,
}

/// A request waiting on the daemon, with the channel to answer on.
pub struct Call {
    request: Request,
    reply: Reply,
}

impl Call {
    /// Splits a call into what was asked and how to answer it, so a handler can
    /// match on the request and still answer from inside the match.
    pub fn split(self) -> (Request, Reply) {
        (self.request, self.reply)
    }
}

/// The other end of one request. Dropping it without answering is allowed: the
/// client simply sees the call time out.
pub struct Reply(Sender<Value>);

impl Reply {
    pub fn answer(self, value: Value) {
        // A client that hung up mid-call is normal, not an error.
        let _ = self.0.send(value);
    }

    /// Answers successfully, merging `value`'s fields into the reply.
    pub fn ok(self, value: Value) {
        let mut body = json!({ "ok": true });
        if let (Some(map), Some(extra)) = (body.as_object_mut(), value.as_object()) {
            for (key, value) in extra {
                map.insert(key.clone(), value.clone());
            }
        }
        self.answer(body);
    }

    pub fn fail(self, message: impl std::fmt::Display) {
        self.answer(json!({ "ok": false, "error": message.to_string() }));
    }
}

pub struct Control {
    calls: Receiver<Call>,
    subscribers: Arc<Mutex<Vec<Sender<String>>>>,
    path: PathBuf,
}

impl Control {
    /// Starts listening. The socket lives in Application Support so it follows
    /// the user, not the machine's temp directory.
    pub fn start() -> Result<Control> {
        let path = socket_path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        // A socket left behind by a killed daemon would otherwise block bind.
        let _ = std::fs::remove_file(&path);

        let listener = UnixListener::bind(&path)
            .with_context(|| format!("binding control socket {}", path.display()))?;

        let (calls_tx, calls) = channel();
        let subscribers: Arc<Mutex<Vec<Sender<String>>>> = Arc::new(Mutex::new(Vec::new()));

        let accept_subscribers = Arc::clone(&subscribers);
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let calls = calls_tx.clone();
                let subscribers = Arc::clone(&accept_subscribers);
                thread::spawn(move || serve(stream, &calls, &subscribers));
            }
        });

        Ok(Control {
            calls,
            subscribers,
            path,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Takes the next waiting call, if any. Never blocks the dock's own loop.
    pub fn next_call(&self) -> Option<Call> {
        self.calls.try_recv().ok()
    }

    /// Sends an event to every subscriber, dropping the ones that have gone.
    pub fn publish(&self, event: Value) {
        let Ok(mut subscribers) = self.subscribers.lock() else {
            return;
        };
        if subscribers.is_empty() {
            return;
        }

        let line = event.to_string();
        subscribers.retain(|tx| tx.send(line.clone()).is_ok());
    }
}

impl Drop for Control {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Handles one client for as long as it stays connected.
fn serve(stream: UnixStream, calls: &Sender<Call>, subscribers: &Arc<Mutex<Vec<Sender<String>>>>) {
    let Ok(write_half) = stream.try_clone() else {
        return;
    };
    let reader = BufReader::new(stream);
    let mut writer = write_half;

    for line in reader.lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }

        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(e) => {
                let _ = writeln!(writer, "{}", json!({ "ok": false, "error": e.to_string() }));
                continue;
            }
        };

        if matches!(request, Request::Subscribe) {
            let (tx, rx) = channel();
            if let Ok(mut list) = subscribers.lock() {
                list.push(tx);
            }
            let _ = writeln!(writer, "{}", json!({ "ok": true, "subscribed": true }));
            // This connection is now an event stream and never reads again.
            for event in rx {
                if writeln!(writer, "{event}").is_err() {
                    return;
                }
            }
            return;
        }

        let (reply_tx, reply_rx) = channel();
        if calls
            .send(Call {
                request,
                reply: Reply(reply_tx),
            })
            .is_err()
        {
            return;
        }

        let answer = match reply_rx.recv_timeout(REPLY_TIMEOUT) {
            Ok(value) => value,
            Err(_) => json!({ "ok": false, "error": "the daemon did not answer" }),
        };

        if writeln!(writer, "{answer}").is_err() {
            return;
        }
    }
}

/// Where the socket lives. Exposed so the app can find it the same way.
pub fn socket_path() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Pult")
        .join("control.sock"))
}
