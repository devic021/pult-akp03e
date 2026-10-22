//! Watches which macOS app is in front and paints the matching scene on the
//! dock. The dock holds no state: every scene change is six images plus a new
//! action table, pushed over HID.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime};

use ajazz_sdk::{new_hidapi, Ajazz, AjazzError, Event};
use image::DynamicImage;
use anyhow::{Context, Result};
use hidapi::HidApi;

use pult::action::{self, Outcome};
use base64::Engine;
use pult::config::{self, Config, Key};
use pult::control::{Call, Control, Request};
use pult::device;
use pult::frontmost;
use pult::permissions;
use pult::render::{Frame, Renderer};
use serde_json::json;

/// How long to block on device input before checking the frontmost app again.
const READ_TIMEOUT: Duration = Duration::from_millis(100);
/// Redraw rate while something on screen is moving. The dock accepts a full
/// six-key repaint in about 5 ms, so this is a comfortable fraction of what it
/// can take.
const FRAME_INTERVAL: Duration = Duration::from_millis(66);
/// A shorter wait on input, so animation frames are not held up by it.
const FRAME_TIMEOUT: Duration = Duration::from_millis(20);
/// How long a key stays lit after being pressed.
const PRESS_FLASH: Duration = Duration::from_millis(180);
/// The dock dims itself if left alone; the SDK's keep-alive prevents that.
const KEEP_ALIVE_EVERY: Duration = Duration::from_secs(30);
/// Pause before looking for the dock again after it goes away.
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

fn main() -> Result<()> {
    let arg = std::env::args().nth(1);
    if matches!(arg.as_deref(), Some("-h" | "--help")) {
        println!("usage: pultd [config.toml]");
        return Ok(());
    }

    let path = config::resolve_path(arg.as_deref())?;
    if config::create_if_missing(&path)? {
        println!("Wrote a starter config to {}", path.display());
    }

    let mut state = State::load(path)?;
    println!(
        "Config  : {} ({} scenes, default {:?})",
        state.path.display(),
        state.config.scenes.len(),
        state.config.default
    );

    check_keystroke_permission(&state.config);

    let control = Control::start()?;
    println!("Control : {}", control.path().display());

    let mut hid = new_hidapi()?;
    loop {
        match run(&hid, &mut state, &control) {
            Ok(()) => return Ok(()),
            Err(e) => eprintln!("\nDock session ended: {e:#}"),
        }

        eprintln!("Waiting for the dock...");
        loop {
            sleep(RECONNECT_DELAY);
            ajazz_sdk::refresh_device_list(&mut hid)?;
            if device::find(&hid).is_ok() {
                break;
            }
        }
    }
}

/// Warns once, before anything is painted, if keystrokes will be dropped.
///
/// macOS attaches the permission to whichever process is held responsible for
/// this one, so rather than guess we ask it to show its own dialog: the app it
/// names there is the app to allow.
fn check_keystroke_permission(config: &Config) {
    if !config.uses_shortcuts() || permissions::accessibility_trusted(true) {
        return;
    }

    eprintln!();
    eprintln!("Keystrokes are blocked: this process is not trusted for Accessibility.");
    eprintln!("macOS was asked to show its permission dialog. Tick the app it names");
    eprintln!("under System Settings > Privacy & Security > Accessibility, then start");
    eprintln!("this again. `run` and `volume` keys work either way.");
    eprintln!();
}

/// Everything that survives a dock disconnect.
struct State {
    path: PathBuf,
    stamp: Option<SystemTime>,
    config: Config,
    renderer: Renderer,
}

impl State {
    fn load(path: PathBuf) -> Result<State> {
        let config = Config::load(&path)?;
        let renderer = Renderer::new(config.font.as_deref(), (60, 60))?;
        Ok(State {
            stamp: modified(&path),
            path,
            config,
            renderer,
        })
    }

    /// Takes a configuration handed over by the app, rebuilding what depends
    /// on it and remembering the file's new timestamp so the watcher does not
    /// reload the write we just made ourselves.
    fn adopt(&mut self, config: Config) -> Result<()> {
        self.renderer = Renderer::new(config.font.as_deref(), self.renderer.size())?;
        self.config = config;
        self.stamp = modified(&self.path);
        Ok(())
    }

    /// How many pages a scene fills on this dock.
    fn pages(&self, scene: &str, display_keys: u8) -> usize {
        self.config
            .scene(scene)
            .map_or(1, |s| s.pages(display_keys as usize))
    }

    /// Picks up edits to the config file. A broken edit is reported and the
    /// running configuration is kept, so a typo cannot kill the daemon.
    fn reload_if_changed(&mut self) -> bool {
        let stamp = modified(&self.path);
        if stamp == self.stamp {
            return false;
        }
        self.stamp = stamp;

        match Config::load(&self.path) {
            Ok(config) => match Renderer::new(config.font.as_deref(), self.renderer.size()) {
                Ok(renderer) => {
                    self.config = config;
                    self.renderer = renderer;
                    println!("Config reloaded");
                    true
                }
                Err(e) => {
                    eprintln!("Config reload failed, keeping the old one: {e:#}");
                    false
                }
            },
            Err(e) => {
                eprintln!("Config reload failed, keeping the old one: {e:#}");
                false
            }
        }
    }
}

/// Runs until the dock stops answering.
fn run(hid: &HidApi, state: &mut State, control: &Control) -> Result<()> {
    let (found, device) = device::open(hid)?;
    // The SDK hands out readers through an Arc; we stay single-threaded, so the
    // missing Send/Sync on the HID handle costs us nothing.
    #[allow(clippy::arc_with_non_send_sync)]
    let device = Arc::new(device);

    println!(
        "Dock    : {:?} serial={} firmware={}",
        found.kind,
        found.serial,
        device.firmware_version().unwrap_or_else(|_| "?".into())
    );

    device
        .set_brightness(state.config.brightness.min(100))
        .context("setting brightness")?;

    // The config is read before we know what is plugged in, so the renderer
    // starts on an assumed key size; adopt the real one now.
    let (kw, kh) = found.kind.key_image_format().size;
    let key_size = (kw as u32, kh as u32);
    if key_size != state.renderer.size() {
        state.renderer = Renderer::new(state.config.font.as_deref(), key_size)?;
    }

    let reader = device.get_reader();
    let display_keys = found.kind.display_key_count();

    let mut app = frontmost::bundle_id();
    let mut active = state.config.scene_for(app.as_deref()).to_string();
    let mut page = 0;
    paint(&device, state, &active, page, display_keys)?;
    report(app.as_deref(), &active, page, state.pages(&active, display_keys));

    let poll_every = Duration::from_millis(state.config.poll_ms.max(50));
    let mut last_poll = Instant::now();
    let mut last_keep_alive = Instant::now();
    let mut painted_at = Instant::now();
    let mut last_frame = Instant::now();
    let mut pressed: Option<(u8, Instant)> = None;

    control.publish(json!({
        "event": "device",
        "connected": true,
        "kind": format!("{:?}", found.kind),
        "serial": found.serial,
    }));

    loop {
        while let Some(call) = control.next_call() {
            match serve(
                call,
                &device,
                state,
                &found,
                app.as_deref(),
                &mut active,
                &mut page,
            ) {
                Ok(true) => {
                    paint(&device, state, &active, page, display_keys)?;
                    painted_at = Instant::now();
                }
                Ok(false) => {}
                Err(e) => eprintln!("control request failed: {e:#}"),
            }
        }

        let moving = pressed.is_some()
            || state
                .config
                .scene(&active)
                .is_some_and(|scene| scene.is_animated(page, display_keys as usize));
        let timeout = if moving { FRAME_TIMEOUT } else { READ_TIMEOUT };

        match reader.read(Some(timeout)) {
            Ok(events) => {
                for event in events {
                    if let Event::ButtonDown(key) = event {
                        if key < display_keys && state.config.press_feedback {
                            pressed = Some((key, Instant::now()));
                        }
                    }
                    control.publish(event_json(&event, &active, page));

                    match handle(event, state, &active, page, display_keys)? {
                        Some(Step::Scene(scene)) => {
                            active = scene;
                            page = 0;
                            paint(&device, state, &active, page, display_keys)?;
                            painted_at = Instant::now();
                            println!("Scene   : {active:?} (by key)");
                            control.publish(json!({
                                "event": "scene",
                                "scene": active,
                                "page": page,
                            }));
                        }
                        Some(Step::Page(target)) => {
                            let pages = state.pages(&active, display_keys);
                            if target != page && target < pages {
                                page = target;
                                paint(&device, state, &active, page, display_keys)?;
                                painted_at = Instant::now();
                                println!("Page    : {} of {pages}", page + 1);
                                control.publish(json!({
                                    "event": "page",
                                    "scene": active,
                                    "page": page,
                                    "pages": pages,
                                }));
                            }
                        }
                        None => {}
                    }
                }
            }
            // Undocumented action codes are not a reason to stop.
            Err(AjazzError::BadData) => {}
            Err(e) => return Err(e).context("reading dock input"),
        }

        if moving && last_frame.elapsed() >= FRAME_INTERVAL {
            last_frame = Instant::now();
            let done = redraw(
                &device,
                state,
                &active,
                page,
                painted_at.elapsed().as_secs_f32(),
                pressed,
                display_keys,
            )?;
            if done {
                pressed = None;
            }
        }

        if last_poll.elapsed() >= poll_every {
            last_poll = Instant::now();

            if state.reload_if_changed() {
                device.set_brightness(state.config.brightness.min(100))?;
                active = state.config.scene_for(app.as_deref()).to_string();
                page = 0;
                paint(&device, state, &active, page, display_keys)?;
                painted_at = Instant::now();
                report(app.as_deref(), &active, page, state.pages(&active, display_keys));
            }

            let current = frontmost::bundle_id();
            if current != app {
                app = current;
                let target = state.config.scene_for(app.as_deref()).to_string();
                if target != active {
                    active = target;
                    page = 0;
                    paint(&device, state, &active, page, display_keys)?;
                    painted_at = Instant::now();
                }
                report(app.as_deref(), &active, page, state.pages(&active, display_keys));
                control.publish(json!({
                    "event": "app",
                    "bundle_id": app,
                    "scene": active,
                    "page": page,
                }));
            }
        }

        if last_keep_alive.elapsed() >= KEEP_ALIVE_EVERY {
            last_keep_alive = Instant::now();
            device.keep_alive().context("sending keep-alive")?;
        }
    }
}

/// Draws one page of a scene onto the keys with displays.
fn paint(
    device: &Ajazz,
    state: &State,
    scene_name: &str,
    page: usize,
    display_keys: u8,
) -> Result<()> {
    let scene = state
        .config
        .scene(scene_name)
        .with_context(|| format!("scene {scene_name:?} vanished from the config"))?;

    let per_page = display_keys as usize;
    let keys = scene.page(page, per_page);
    let marker = marker(page, scene.pages(per_page));

    for index in 0..display_keys {
        match keys.get(index as usize) {
            Some(key) => {
                let frame = Frame {
                    pages: marker,
                    ..Frame::at(0.0)
                };
                let image = draw(state, key, frame, scene_name, index);
                device
                    .set_button_image(index, image)
                    .with_context(|| format!("sending image for key {index}"))?;
            }
            None => device.clear_button_image(index)?,
        }
    }

    device.flush().context("flushing images")?;
    Ok(())
}

/// The page strip to draw, or nothing when a scene fits on one page.
fn marker(page: usize, pages: usize) -> Option<(usize, usize)> {
    (pages > 1).then_some((page, pages))
}

/// Renders a key, falling back to a plain one when its art will not draw.
///
/// A missing icon or a malformed colour is a mistake in the config; losing the
/// dock over it would be a far worse answer than showing a bare label.
fn draw(state: &State, key: &Key, frame: Frame, scene: &str, index: u8) -> DynamicImage {
    match state.renderer.key_frame(key, frame) {
        Ok(image) => image,
        Err(e) => {
            eprintln!("key {index} of scene {scene:?} will not draw: {e:#}");

            let plain = Key {
                label: key.label.clone(),
                color: key.color.clone(),
                ..Key::default()
            };
            state
                .renderer
                .key_frame(&plain, Frame::default())
                .unwrap_or_else(|_| {
                    let (w, h) = state.renderer.size();
                    DynamicImage::ImageRgb8(image::RgbImage::new(w, h))
                })
        }
    }
}

/// Redraws only what moves: animated keys, and the key being pressed.
///
/// Returns whether the press highlight has finished, which is the caller's cue
/// to forget it. The last frame of a press is drawn at full rest, so the key
/// never stays lit.
fn redraw(
    device: &Ajazz,
    state: &State,
    scene_name: &str,
    page: usize,
    time: f32,
    pressed: Option<(u8, Instant)>,
    display_keys: u8,
) -> Result<bool> {
    let Some(scene) = state.config.scene(scene_name) else {
        return Ok(true);
    };

    let per_page = display_keys as usize;
    let pages = marker(page, scene.pages(per_page));
    let press_over = pressed.is_some_and(|(_, at)| at.elapsed() >= PRESS_FLASH);
    let mut drawn = false;

    for (index, key) in scene.page(page, per_page).iter().enumerate() {
        let index = index as u8;
        let press = match pressed {
            Some((k, at)) if k == index => {
                let t = at.elapsed().as_secs_f32() / PRESS_FLASH.as_secs_f32();
                (1.0 - t).clamp(0.0, 1.0).powi(2)
            }
            _ => 0.0,
        };

        let touched = pressed.is_some_and(|(k, _)| k == index);
        if key.animate.is_none() && !touched {
            continue;
        }

        let frame = Frame { time, press, pages };
        let image = draw(state, key, frame, scene_name, index);
        device
            .set_button_image(index, image)
            .with_context(|| format!("sending frame for key {index}"))?;
        drawn = true;
    }

    if drawn {
        device.flush().context("flushing animation frame")?;
    }

    Ok(press_over)
}

/// What a key press asks the daemon to do next.
enum Step {
    Scene(String),
    Page(usize),
}

/// Runs what an event is bound to; returns where to go next, if anywhere.
fn handle(
    event: Event,
    state: &State,
    active: &str,
    page: usize,
    display_keys: u8,
) -> Result<Option<Step>> {
    let Some(scene) = state.config.scene(active) else {
        return Ok(None);
    };

    let per_page = display_keys as usize;
    let (action, what) = match event {
        Event::ButtonDown(key) if key < display_keys => (
            scene.page(page, per_page).get(key as usize).map(|k| &k.action),
            format!("key {key}"),
        ),
        Event::ButtonDown(key) => (
            scene.buttons.get((key - display_keys) as usize),
            format!("button {key}"),
        ),
        Event::EncoderDown(e) => (
            scene.encoders.get(e as usize).map(|enc| &enc.press),
            format!("encoder {e} press"),
        ),
        Event::EncoderTwist(e, delta) => {
            let encoder = scene.encoders.get(e as usize);
            let action = encoder.map(|enc| if delta > 0 { &enc.cw } else { &enc.ccw });
            let direction = if delta > 0 { "cw" } else { "ccw" };
            (action, format!("encoder {e} {direction}"))
        }
        // Releases carry no binding of their own.
        Event::ButtonUp(_) | Event::EncoderUp(_) => return Ok(None),
    };

    match action {
        Some(action) if !action.is_empty() => {
            // Every event gets a line: a log that only shows failures cannot
            // tell you which physical knob is which.
            println!("{what} -> {}", action::describe(action));

            match action::run(action) {
                Ok(Outcome::SwitchScene(scene)) => Ok(Some(Step::Scene(scene))),
                Ok(Outcome::TurnPage(turn)) => {
                    let pages = scene.pages(per_page);
                    Ok(Some(Step::Page(turn.apply(page, pages))))
                }
                Ok(Outcome::Nothing) => Ok(None),
                // A failed action is the user's problem to fix, not a reason to quit.
                Err(e) => {
                    eprintln!("{what} failed: {e:#}");
                    Ok(None)
                }
            }
        }
        _ => {
            println!("{what} is not bound in scene {active:?}");
            Ok(None)
        }
    }
}

/// Turns a dock event into something the app can show.
fn event_json(event: &Event, scene: &str, page: usize) -> serde_json::Value {
    let (kind, index, detail) = match event {
        Event::ButtonDown(key) => ("key_down", *key, None),
        Event::ButtonUp(key) => ("key_up", *key, None),
        Event::EncoderDown(e) => ("encoder_down", *e, None),
        Event::EncoderUp(e) => ("encoder_up", *e, None),
        Event::EncoderTwist(e, delta) => (
            "encoder_twist",
            *e,
            Some(if *delta > 0 { "cw" } else { "ccw" }),
        ),
    };

    json!({
        "event": kind,
        "index": index,
        "direction": detail,
        "scene": scene,
        "page": page,
    })
}

/// Answers one request from the app. Returns whether the dock needs repainting.
fn serve(
    call: Call,
    device: &Ajazz,
    state: &mut State,
    found: &device::Found,
    app: Option<&str>,
    active: &mut String,
    page: &mut usize,
) -> Result<bool> {
    let display_keys = found.kind.display_key_count();
    let (request, reply) = call.split();
    match request {
        Request::Status => {
            let pages = state.pages(active, display_keys);
            reply.ok(json!({
                "device": {
                    "kind": format!("{:?}", found.kind),
                    "serial": found.serial,
                    "firmware": device.firmware_version().unwrap_or_else(|_| "?".into()),
                    "keys": display_keys,
                    "encoders": found.kind.encoder_count(),
                    "buttons": found.kind.key_count() - display_keys,
                    "key_size": state.renderer.size(),
                    "boot_logo": found.kind.boot_logo_size(),
                },
                "scene": active,
                "page": page,
                "pages": pages,
                "app": app,
                "config_path": state.path,
                "keystrokes_allowed": pult::permissions::accessibility_trusted(false),
            }));
            Ok(false)
        }

        Request::Config => {
            reply.answer(json!({ "ok": true, "config": state.config }));
            Ok(false)
        }

        Request::SetConfig { config } => {
            // Validation lives in one place, so the app cannot write a file the
            // daemon would then refuse to load.
            match config.save(&state.path) {
                Ok(()) => {
                    state.adopt(*config.clone())?;
                    if !state.config.scenes.contains_key(active.as_str()) {
                        *active = state.config.scene_for(app).to_string();
                    }
                    *page = 0;
                    device.set_brightness(state.config.brightness.min(100))?;
                    reply.ok(json!({ "saved": true }));
                    Ok(true)
                }
                Err(e) => {
                    reply.fail(format!("{e:#}"));
                    Ok(false)
                }
            }
        }

        Request::Icons => {
            reply.ok(json!({ "icons": pult::icons::names() }));
            Ok(false)
        }

        Request::Icon { name, size, color } => {
            let key = Key {
                icon: Some(name),
                icon_color: color,
                color: Some("#00000000".to_string()),
                ..Key::default()
            };
            let size = size.unwrap_or(64);
            match Renderer::new(state.config.font.as_deref(), (size, size))
                .and_then(|r| r.key_frame(&key, Frame::default()))
                .and_then(|image| encode_png(&image))
            {
                Ok(png) => reply.ok(json!({ "png": png })),
                Err(e) => reply.fail(format!("{e:#}")),
            }
            Ok(false)
        }

        Request::RenderKey { key, size, pages } => {
            let size = size.map_or_else(|| state.renderer.size(), |s| (s, s));
            let frame = Frame {
                pages,
                ..Frame::default()
            };
            match Renderer::new(state.config.font.as_deref(), size)
                .and_then(|r| r.key_frame(&key, frame))
                .and_then(|image| encode_png(&image))
            {
                Ok(png) => reply.ok(json!({ "png": png })),
                Err(e) => reply.fail(format!("{e:#}")),
            }
            Ok(false)
        }

        Request::Preview { scene, page: want } => {
            let Some(found_scene) = state.config.scene(&scene) else {
                reply.fail(format!("no scene named {scene:?}"));
                return Ok(false);
            };

            let per_page = display_keys as usize;
            let pages = found_scene.pages(per_page);
            let marker = (pages > 1).then_some((want, pages));
            let mut images = Vec::new();
            for key in found_scene.page(want, per_page) {
                let frame = Frame {
                    pages: marker,
                    ..Frame::default()
                };
                let image = state.renderer.key_frame(key, frame)?;
                images.push(encode_png(&image)?);
            }

            reply.ok(json!({ "keys": images, "pages": pages }));
            Ok(false)
        }

        Request::Brightness { value } => {
            match device.set_brightness(value.min(100)) {
                Ok(()) => reply.ok(json!({})),
                Err(e) => reply.fail(e),
            }
            Ok(false)
        }

        Request::Scene { name } => {
            if !state.config.scenes.contains_key(&name) {
                reply.fail(format!("no scene named {name:?}"));
                return Ok(false);
            }
            *active = name;
            *page = 0;
            reply.ok(json!({ "scene": active }));
            Ok(true)
        }

        Request::Page { value } => {
            let pages = state.pages(active, display_keys);
            if value >= pages {
                reply.fail(format!("page {} of {pages}", value + 1));
                return Ok(false);
            }
            *page = value;
            reply.ok(json!({ "page": page }));
            Ok(true)
        }

        Request::BootLogo { path } => {
            // The only thing the dock keeps when it is unplugged.
            match image::open(&path)
                .map_err(anyhow::Error::from)
                .and_then(|image| device.set_logo_image(image).map_err(anyhow::Error::from))
            {
                Ok(()) => reply.ok(json!({ "written": true })),
                Err(e) => reply.fail(format!("{e:#}")),
            }
            Ok(false)
        }

        Request::Sleep => {
            match device.sleep() {
                Ok(()) => reply.ok(json!({})),
                Err(e) => reply.fail(e),
            }
            Ok(false)
        }

        Request::Wake => {
            device.set_brightness(state.config.brightness.min(100))?;
            reply.ok(json!({}));
            Ok(true)
        }

        // Handled inside the socket server, which turns the connection into a
        // one-way event stream instead of answering.
        Request::Subscribe => {
            reply.ok(json!({}));
            Ok(false)
        }
    }
}

fn encode_png(image: &image::DynamicImage) -> Result<String> {
    let mut bytes = std::io::Cursor::new(Vec::new());
    image
        .write_to(&mut bytes, image::ImageFormat::Png)
        .context("encoding PNG")?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes.into_inner()))
}

fn report(app: Option<&str>, scene: &str, page: usize, pages: usize) {
    let where_ = if pages > 1 {
        format!("scene {scene:?} page {} of {pages}", page + 1)
    } else {
        format!("scene {scene:?}")
    };
    println!("Front   : {:<40} {where_}", app.unwrap_or("-"));
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).ok()?.modified().ok()
}
