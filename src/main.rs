//! Watches which macOS app is in front and paints the matching scene on the
//! dock. The dock holds no state: every scene change is six images plus a new
//! action table, pushed over HID.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime};

use ajazz_sdk::{new_hidapi, Ajazz, AjazzError, Event};
use image::DynamicImage;
use anyhow::{Context, Result};
use hidapi::HidApi;

use pult::action::{self, Outcome};
use base64::Engine;
use pult::canvas::{self, Canvas};
use pult::power::{self, Sleeping};
use pult::config::{self, Config, Hour, Key, Surface};
use pult::feed::{self, Feeds};
use pult::control::{Call, Control, Request};
use pult::device;
use pult::frontmost;
use pult::permissions;
use pult::render::{Frame, Readout, Renderer};
use pult::values::Bindings;
use serde_json::json;

/// How long to block on device input before looking at anything else.
///
/// This also bounds how long a request from the app waits before the loop
/// notices it, so it is short enough that dragging a slider feels direct. The
/// thread is asleep in the kernel for all of it.
const READ_TIMEOUT: Duration = Duration::from_millis(40);
/// Redraw rate while something on screen is moving. The dock accepts a full
/// six-key repaint in about 5 ms, so this is a comfortable fraction of what it
/// can take.
const FRAME_INTERVAL: Duration = Duration::from_millis(66);
/// The shortest the loop will wait on input, so a frame deadline that is
/// almost due does not turn into a busy spin.
const MIN_TIMEOUT: Duration = Duration::from_millis(2);
/// How long a key stays lit after being pressed.
const PRESS_FLASH: Duration = Duration::from_millis(180);

/// How long the dock shows the output level after it changes.
///
/// Long enough to read while the hand is still on the knob, short enough that
/// the page you were looking at is not taken away from you.
const METER_HOLDS: Duration = Duration::from_millis(1200);

/// How long a scrubbed forecast holds before it comes back to now.
///
/// It must come back on its own: a dock left three hours ahead is a dock
/// quietly showing the wrong weather, and nobody remembers turning the knob.
const SCRUB_HOLDS: Duration = Duration::from_secs(20);
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
    /// What the feeds have last said. Shared with their threads; the loop only
    /// ever reads it.
    bindings: Arc<Mutex<Bindings>>,
    /// The running pollers. Dropping them stops them, which is how a config
    /// reload replaces one set with another.
    feeds: Option<Feeds>,
    /// Where the dock is, read from a file of its own so that a home address
    /// never lands in the config the app round-trips and backs up.
    places: BTreeMap<String, String>,
    place_stamp: Option<SystemTime>,
    /// Which of its readings each key is showing, by scene and key.
    views: BTreeMap<(String, u8), usize>,
    /// Hours ahead of now that the scene is reading, and when the knob last
    /// moved; zero is the present.
    hour: i32,
    scrubbed_at: Option<Instant>,
    /// The text last sent to each key, so a reading is pushed when it changes
    /// and not when its feed merely answered again.
    painted: RefCell<BTreeMap<(String, u8), String>>,
}

impl State {
    fn load(path: PathBuf) -> Result<State> {
        let config = Config::load(&path)?;
        let renderer = Renderer::new(config.font.as_deref(), (60, 60))?;
        let mut state = State {
            stamp: modified(&path),
            path,
            config,
            renderer,
            bindings: Arc::new(Mutex::new(Bindings::new())),
            feeds: None,
            places: feed::places(),
            place_stamp: feed::place_path().as_deref().and_then(modified),
            views: BTreeMap::new(),
            hour: 0,
            scrubbed_at: None,
            painted: RefCell::new(BTreeMap::new()),
        };
        state.restart_feeds();
        Ok(state)
    }

    /// Replaces the running pollers with the ones this config asks for.
    ///
    /// The old set is dropped first, so a renamed feed's thread is gone before
    /// its replacement starts and two of them cannot write the same name.
    fn restart_feeds(&mut self) {
        self.feeds = None;
        self.painted.borrow_mut().clear();
        if self.config.feeds.is_empty() {
            return;
        }
        self.places = feed::places();
        self.place_stamp = feed::place_path().as_deref().and_then(modified);
        self.feeds = Some(Feeds::start(
            &self.config.feeds,
            &self.places,
            Arc::clone(&self.bindings),
        ));
        println!("Feeds   : {} polling", self.config.feeds.len());
    }

    /// What the feeds have said, for reading.
    ///
    /// A poller that panicked must not take the dock down with it, so the lock
    /// is taken back rather than unwrapped.
    fn bindings(&self) -> std::sync::MutexGuard<'_, Bindings> {
        self.bindings.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether the coordinates file has been touched since it was last read.
    fn place_changed(&mut self) -> bool {
        let stamp = feed::place_path().as_deref().and_then(modified);
        if stamp == self.place_stamp {
            return false;
        }
        self.place_stamp = stamp;
        true
    }

    /// How far a knob may walk this scene.
    ///
    /// What the scene asks for, held down to what the feeds actually brought
    /// back. Configuring forty-eight hours against a day of data would put
    /// half the dial past the end of the forecast.
    fn span(&self, scene: &str) -> usize {
        let available = self.bindings().span();
        let asked = self
            .config
            .scene(scene)
            .and_then(|scene| scene.hours)
            .unwrap_or(available);
        asked.clamp(1, available.max(1))
    }

    /// The scrub indicator, or nothing while the scene reads the present.
    fn scrub_marker(&self, scene: &str) -> Option<(usize, usize)> {
        (self.hour != 0).then(|| (self.hour.unsigned_abs() as usize, self.span(scene)))
    }

    /// Which reading a key is showing.
    fn view_of(&self, scene: &str, index: u8) -> usize {
        self.views
            .get(&(scene.to_string(), index))
            .copied()
            .unwrap_or(0)
    }

    /// Takes a configuration handed over by the app, rebuilding what depends
    /// on it and remembering the file's new timestamp so the watcher does not
    /// reload the write we just made ourselves.
    fn adopt(&mut self, config: Config) -> Result<()> {
        self.renderer = Renderer::new(config.font.as_deref(), self.renderer.size())?;
        let feeds_changed = feeds_differ(&self.config, &config);
        self.config = config;
        self.stamp = modified(&self.path);
        if feeds_changed {
            self.restart_feeds();
        }
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
                    let feeds_changed = feeds_differ(&self.config, &config);
                    self.config = config;
                    self.renderer = renderer;
                    if feeds_changed {
                        self.restart_feeds();
                    }
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
    // Decoded once, when a scene starts showing it: the loop has five
    // milliseconds a frame and a full-size GIF costs more than that to decode.
    let mut loaded: Option<(String, pult::animation::Animation)> = None;

    paint(
        &device,
        state,
        &active,
        page,
        display_keys,
        &found,
        animation_for(&mut loaded, state, &active, &found),
    )?;
    report(app.as_deref(), &active, page, state.pages(&active, display_keys));

    let poll_every = Duration::from_millis(state.config.poll_ms.max(50));
    let mut last_poll = Instant::now();
    let mut last_keep_alive = Instant::now();
    let mut painted_at = Instant::now();
    // The phase the effects are drawn at, in tau-seconds. Advanced by
    // `dt * speed` rather than read off the clock, so turning the speed knob
    // changes how fast the picture moves and never where it currently is.
    let mut tau = 0.0f32;
    // Read when a config is loaded, not per frame: it is a preference, and the
    // daemon has no run loop to be notified on.
    let mut reduced = pult::idle::reduce_motion();
    for line in state.config.missing_files() {
        eprintln!("Config  : {line}");
    }
    // The dock's own keys are not a keyboard, so CoreGraphics never sees them:
    // without this the dock would fall asleep under your hand.
    let mut touched = Instant::now();
    let mut resting = false;
    let mut dark = false;
    let mut swallow_press = false;
    // A surface the editor is trying out, and when the trial lapses. Expiry
    // rather than an explicit stop: a crashed editor must not leave the dock
    // showing something nobody saved.
    let mut trying: Option<(Surface, Instant)> = None;
    let mut trial_mark: Option<Instant> = None;
    // Decoded once when the trial begins, not per frame.
    let mut trial_film: Option<pult::animation::Animation> = None;
    // Told before the Mac goes down, so the frame it holds all night is one we
    // chose. Nothing here keeps the Mac awake, it only asks to paint first.
    let sleeping = power::watch_sleep();
    // A deadline, not an elapsed check: waiting 20 ms at a time and then asking
    // whether 66 ms had passed meant the first eligible iteration landed at 80,
    // so the advertised 15 fps was really 12.5 and drifted with the work done
    // in between.
    let mut next_frame = Instant::now() + FRAME_INTERVAL;
    let mut pressed: Option<(u8, Instant)> = None;
    // The output level, while it is worth showing. macOS draws its own
    // overlay only for a real key press, which would mean asking for the
    // right to send keystrokes and a round trip per detent; this is where the
    // hand already is.
    let mut meter: Option<Instant> = None;

    control.publish(json!({
        "event": "device",
        "connected": true,
        "kind": format!("{:?}", found.kind),
        "serial": found.serial,
    }));

    // Opt-in timing, because guessing where a loop spends its time is how you
    // end up optimising the wrong thing.
    let trace = std::env::var_os("PULT_TRACE").is_some();
    let mut trace_since = Instant::now();
    let mut trace_iterations = 0u32;
    let mut trace_read = Duration::ZERO;
    let mut trace_rest = Duration::ZERO;

    loop {
        let iteration_started = Instant::now();

        while let Some(call) = control.next_call() {
            match serve(
                call,
                &device,
                state,
                &found,
                app.as_deref(),
                &mut active,
                &mut page,
                &mut trying,
            ) {
                Ok(true) => {
                    paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                    painted_at = Instant::now();
                    tau = 0.0;
                }
                Ok(false) => {}
                Err(e) => eprintln!("control request failed: {e:#}"),
            }
        }

        if let Some((_, until)) = trying {
            if Instant::now() >= until {
                trying = None;
                paint(
                    &device,
                    state,
                    &active,
                    page,
                    display_keys,
                    &found,
                    animation_for(&mut loaded, state, &active, &found),
                )?;
                painted_at = Instant::now();
                tau = 0.0;
                println!("Try     : over");
            }
        }

        // A trial is started from the socket thread's side of `serve`, which
        // cannot reach the phase. So the loop notices it here instead: a new
        // expiry means a new trial, and a trial has to start at the beginning
        // of its motion or you are judging it from the middle.
        let trial = trying.as_ref().map(|(_, until)| *until);
        if trial != trial_mark {
            trial_mark = trial;
            painted_at = Instant::now();
            tau = 0.0;
            // The file the trial names, decoded here and not on every frame.
            // Without this the trial fell through to `Effect::Sweep` and showed
            // a blue wipe whatever file you had picked, which is the one thing
            // a trial must never do, since watching the real seams cut the real
            // motion is the entire reason to run one.
            trial_film = trying.as_ref().and_then(|(surface, _)| decode(surface, &found));
        }

        let surface = painting(state, &active, trying.as_ref());
        let (interval, speed) = clock(surface);
        // Two reasons a canvas stops without the dock going dark: macOS has
        // been asked for less motion, or the scene is one you work in and said
        // to settle after a while. Either way the last frame simply stays.
        let still = surface.is_some_and(|surface| {
            (reduced && surface.respects_reduce_motion())
                || surface
                    .stop_after()
                    .is_some_and(|after| painted_at.elapsed() > after)
        });
        let animated = state
            .config
            .scene(&active)
            .is_some_and(|scene| scene.is_animated(page, display_keys as usize));
        // A press flash is feedback, not decoration, so it keeps moving even
        // when everything else has settled.
        let moving = pressed.is_some() || ((trying.is_some() || animated) && !still);
        let timeout = if moving {
            // Sleep exactly up to the next frame, never past it.
            next_frame
                .saturating_duration_since(Instant::now())
                .clamp(MIN_TIMEOUT, READ_TIMEOUT)
        } else {
            READ_TIMEOUT
        };

        let read_started = Instant::now();
        let input = reader.read(Some(timeout));
        let read_took = read_started.elapsed();

        match input {
            Ok(events) => {
                for event in events {
                    touched = Instant::now();

                    // Waking the dock with a slap must not also fire whatever
                    // that key does; it would feel broken to whoever learns it.
                    if swallow_press {
                        swallow_press = false;
                        control.publish(event_json(&event, &active, page));
                        continue;
                    }

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

                            // While the dock is pinned, choosing a scene
                            // chooses the pinned one. Otherwise a single press
                            // defeats the pin and leaves the dock on the new
                            // scene until an application changes, which with a
                            // pin set can be never: the thing you pinned so it
                            // would stay is the one thing that does not.
                            if state.config.pinned.is_some()
                                && state.config.pinned.as_deref() != Some(active.as_str())
                            {
                                state.config.pinned = Some(active.clone());
                                match state.config.save(&state.path) {
                                    Ok(()) => state.stamp = modified(&state.path),
                                    Err(e) => eprintln!("could not move the pin: {e:#}"),
                                }
                                println!("Pinned  : {active:?}");
                            }
                            paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                            painted_at = Instant::now();
                            tau = 0.0;
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
                                paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                                painted_at = Instant::now();
                                tau = 0.0;
                                println!("Page    : {} of {pages}", page + 1);
                                control.publish(json!({
                                    "event": "page",
                                    "scene": active,
                                    "page": page,
                                    "pages": pages,
                                }));
                            }
                        }
                        Some(Step::Sound(sound, silence)) => {
                            paint_meter(&device, &found, sound, silence)?;
                            meter = Some(Instant::now() + METER_HOLDS);
                        }
                        Some(Step::Cycle(index)) => {
                            let views = state
                                .config
                                .scene(&active)
                                .and_then(|scene| {
                                    scene.page(page, display_keys as usize).get(index as usize).map(Key::views)
                                })
                                .unwrap_or(1);
                            let next = (state.view_of(&active, index) + 1) % views.max(1);
                            state.views.insert((active.clone(), index), next);
                            println!("key {index} -> reading {}", next + 1);
                            // One key, 1.2 ms: nothing else on the page moved.
                            refresh(&device, state, &active, page, display_keys)?;
                        }
                        Some(Step::Scrub(hour)) => {
                            let before = state.hour;
                            let span = state.span(&active) as i32;
                            state.hour = match hour {
                                Hour::Next => (state.hour + 1).min(span - 1),
                                Hour::Prev => (state.hour - 1).max(0),
                                Hour::Now => 0,
                            };
                            state.scrubbed_at = (state.hour != 0).then(Instant::now);
                            if state.hour != before {
                                // The whole page moves together: one key an
                                // hour ahead of the other five is a page of
                                // numbers that do not belong to each other.
                                paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                                painted_at = Instant::now();
                                tau = 0.0;
                                println!("Hour    : +{}h", state.hour);
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

        if let Some(events) = sleeping.as_ref() {
            while let Ok(event) = events.try_recv() {
                match event {
                    Sleeping::Soon(permission) => {
                        if let Some(image) =
                            state.config.idle.as_ref().and_then(|i| i.sleep_image.as_ref())
                        {
                            println!("Sleep   : leaving {}", image.display());
                            if let Err(e) = paint_image(&device, &found, image) {
                                eprintln!("sleep picture failed: {e:#}");
                            }
                        }
                        // Dropping the permission is what lets the Mac go. It
                        // must happen whatever the painting did.
                        drop(permission);
                    }
                    Sleeping::Woke => {
                        println!("Sleep   : awake");
                        touched = Instant::now();
                        resting = false;
                        dark = false;
                        device.set_brightness(state.config.brightness.min(100))?;
                        paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                        painted_at = Instant::now();
                        tau = 0.0;
                    }
                }
            }
        }

        if moving && meter.is_none() && Instant::now() >= next_frame {
            // Advance by whole intervals so the clock keeps its rate; if a slow
            // iteration put us past several, drop them rather than catch up in
            // a burst.
            next_frame += interval;
            let now = Instant::now();
            if next_frame <= now {
                next_frame = now + interval;
            }
            tau += interval.as_secs_f32() * speed;

            // An if, not a `continue`: the branch used to skip the rest of the
            // iteration, which at 15 fps was harmless because there were spare
            // iterations to spend. At 30 there are none, and a fast canvas
            // would stop noticing app switches and never send a keep-alive,
            // and without one the dock dims itself.
            if let Some((surface, _)) = trying.as_ref() {
                // While a trial is running the dock shows it and nothing else.
                paint_canvas(&device, surface, &found, tau, trial_film.as_ref())?;
            } else {
                let done = redraw(
                    &device,
                    state,
                    &active,
                    page,
                    tau,
                    pressed,
                    display_keys,
                    &found,
                    animation_for(&mut loaded, state, &active, &found),
                )?;
                if done {
                    pressed = None;
                }
            }
        }

        if let Some(until) = meter {
            if Instant::now() >= until {
                meter = None;
                paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                painted_at = Instant::now();
                tau = 0.0;
            }
        }

        // Outside the frame tick on purpose: a number arriving must not have
        // to wait for an animation clock that a still scene never starts.
        if trying.is_none() && meter.is_none() {
            refresh(&device, state, &active, page, display_keys)?;
        }

        if last_poll.elapsed() >= poll_every {
            last_poll = Instant::now();

            if state.place_changed() {
                println!("Place   : changed on disk");
                state.restart_feeds();
            }

            if let Some(at) = state.scrubbed_at {
                if at.elapsed() >= SCRUB_HOLDS {
                    state.scrubbed_at = None;
                    if state.hour != 0 {
                        state.hour = 0;
                        paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                        painted_at = Instant::now();
                        tau = 0.0;
                        println!("Hour    : back to now");
                    }
                }
            }

            if state.reload_if_changed() {
                for line in state.config.missing_files() {
                    eprintln!("Config  : {line}");
                }
                // Announced, or an editor sitting open keeps a snapshot taken
                // before the change and writes it back on the next save,
                // quietly deleting whatever was edited on disk meanwhile.
                control.publish(json!({ "event": "config" }));
                reduced = pult::idle::reduce_motion();
                device.set_brightness(state.config.brightness.min(100))?;
                active = state.config.scene_for(app.as_deref()).to_string();
                page = 0;
                paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                painted_at = Instant::now();
                tau = 0.0;
                report(app.as_deref(), &active, page, state.pages(&active, display_keys));
            }

            if let Some(rest) = state.config.idle.clone() {
                let asleep = rest.dark_when_display_sleeps && pult::idle::display_asleep();
                let alone = pult::idle::since_input().min(touched.elapsed()) >= rest.after();

                if asleep {
                    // Nothing is watching: light the room for no one is exactly
                    // what an idle screen is supposed to avoid.
                    if !dark {
                        device.sleep().context("sleeping the dock")?;
                        dark = true;
                        resting = false;
                    }
                } else {
                    if dark {
                        dark = false;
                        device.set_brightness(state.config.brightness.min(100))?;
                        paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                        painted_at = Instant::now();
                        tau = 0.0;
                    }

                    if alone && !resting && active != rest.scene {
                        resting = true;
                        active = rest.scene.clone();
                        page = 0;
                        // The dim lands in the same instant as the repaint:
                        // brightness steps on this device are seen, not felt.
                        device.set_brightness(rest.brightness())?;
                        paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                        painted_at = Instant::now();
                        tau = 0.0;
                        println!("Idle    : resting on {:?}", active);
                        control.publish(json!({ "event": "idle", "resting": true, "scene": active }));
                    } else if !alone && resting {
                        resting = false;
                        swallow_press = rest.swallow_first_press;
                        // Back to whatever the frontmost application asks for,
                        // not to whatever happened to be showing before.
                        active = state.config.scene_for(app.as_deref()).to_string();
                        page = 0;
                        device.set_brightness(state.config.brightness.min(100))?;
                        paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                        painted_at = Instant::now();
                        tau = 0.0;
                        println!("Idle    : awake on {:?}", active);
                        control.publish(json!({ "event": "idle", "resting": false, "scene": active }));
                    }
                }
            }

            let current = frontmost::bundle_id();
            if current != app {
                app = current;
                let target = state.config.scene_for(app.as_deref()).to_string();
                if resting {
                    // An application switching in the background does not end
                    // the rest; only a person does.
                } else if target != active {
                    active = target;
                    page = 0;
                    paint(&device, state, &active, page, display_keys, &found, animation_for(&mut loaded, state, &active, &found))?;
                    painted_at = Instant::now();
                    tau = 0.0;
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

        if trace {
            trace_iterations += 1;
            trace_read += read_took;
            trace_rest += iteration_started.elapsed() - read_took;

            if trace_since.elapsed() >= Duration::from_secs(2) {
                let n = trace_iterations.max(1);
                println!(
                    "trace   : {n} loops in {:?}, read {:?} each, rest {:?} each",
                    trace_since.elapsed(),
                    trace_read / n,
                    trace_rest / n
                );
                trace_since = Instant::now();
                trace_iterations = 0;
                trace_read = Duration::ZERO;
                trace_rest = Duration::ZERO;
            }
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
    found: &device::Found,
    animation: Option<&pult::animation::Animation>,
) -> Result<()> {
    let scene = state
        .config
        .scene(scene_name)
        .with_context(|| format!("scene {scene_name:?} vanished from the config"))?;

    if let Some(surface) = scene.canvas() {
        return paint_canvas(device, surface, found, 0.0, animation);
    }

    let per_page = display_keys as usize;
    let keys = scene.page(page, per_page);
    let marker = marker(page, scene.pages(per_page));
    let hour = state.scrub_marker(scene_name);

    // A full repaint is the baseline every later change is measured against,
    // so the record of what is on the keys starts again here.
    state.painted.borrow_mut().clear();

    for index in 0..display_keys {
        match keys.get(index as usize) {
            Some(key) => {
                let frame = Frame {
                    pages: marker,
                    hour,
                    ..Frame::at(0.0)
                };
                let image = draw(state, key, frame, scene_name, index);
                device
                    .set_button_image(index, image)
                    .with_context(|| format!("sending image for key {index}"))?;
                if key.live() {
                    state
                        .painted
                        .borrow_mut()
                        .insert((scene_name.to_string(), index), output_of(state, key, scene_name, index));
                }
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

/// Renders a canvas to frames of tiles, for the editor to watch.
///
/// Off the dock entirely: nothing here touches the device, so whatever is on
/// the keys stays on them.
fn render_preview(
    surface: Surface,
    geometry: (u32, u32, u32),
    frames: Option<usize>,
    fps: Option<u8>,
) -> Result<serde_json::Value> {
    let (cols, rows, key) = geometry;

    // A file of one's own is decoded and played back; otherwise the effect is
    // drawn, for one loop of its own period.
    if let Some(source) = surface.source.as_ref() {
        let mapping = surface.mapping.unwrap_or(canvas::Mapping::Physical);
        let animation =
            pult::animation::Animation::load(
                source,
                mapping,
                cols,
                rows,
                key,
                surface.fps,
                surface.fit,
                surface.rotate,
                surface
                    .background
                    .as_deref()
                    .map(pult::render::parse_color)
                    .transpose()?
                    .unwrap_or(image::Rgb([8, 9, 12])),
            )?;

        let wanted = frames.unwrap_or(animation.frames()).clamp(1, 60);
        let step = animation.duration().as_secs_f32() / wanted as f32;
        let mut out = Vec::with_capacity(wanted);
        for index in 0..wanted {
            let frame = animation.at(index as f32 * step);
            out.push(
                frame
                    .tiles
                    .iter()
                    .map(|tile| encode_png(&image::DynamicImage::ImageRgb8(tile.clone())))
                    .collect::<Result<Vec<_>>>()?,
            );
        }

        return Ok(json!({
            "frames": out,
            "fps": (wanted as f32 / animation.duration().as_secs_f32().max(0.01)).round(),
            "seconds": animation.duration().as_secs_f32(),
            "source": true,
            "clipped": wanted < animation.frames(),
        }));
    }

    let effect = surface.effect.unwrap_or(canvas::Effect::Sweep);
    let mapping = surface.mapping_for(effect);
    let rate = fps.unwrap_or_else(|| surface.fps_for(effect));
    let period = effect.period();
    let wanted = frames
        .unwrap_or_else(|| (period * f32::from(rate)).round() as usize)
        .clamp(1, 60);

    let mut canvas = Canvas::new(mapping, cols, rows, key);
    let step = period / wanted as f32;
    let mut out = Vec::with_capacity(wanted);

    for index in 0..wanted {
        // The style is rebuilt per frame because `color_cycle` is a function of
        // tau like everything else; one loop of the preview is one loop of the
        // motion, not of the colour.
        let tau = index as f32 * step;
        let style = surface.style(tau, effect)?;
        canvas::draw(effect, &mut canvas, tau, &style);
        out.push(
            (0..canvas.keys())
                .map(|tile| encode_png(&image::DynamicImage::ImageRgb8(canvas.tile(tile))))
                .collect::<Result<Vec<_>>>()?,
        );
    }

    Ok(json!({
        "frames": out,
        "fps": rate,
        "seconds": period,
        "source": false,
        "clipped": false,
    }))
}

/// Returns the animation this scene draws with, decoding it if the scene has
/// only just started showing it.
///
/// Held by scene name so switching back and forth does not decode twice, and
/// dropped as soon as another scene brings its own.
/// Decodes the file a surface names, if it names one.
///
/// Pulled out of the scene cache because a trial surface is not in the config
/// and so cannot be looked up by scene name, and a trial that silently showed
/// a blue sweep instead of the file you picked was defeating the only reason
/// the trial exists.
fn decode(surface: &Surface, found: &device::Found) -> Option<pult::animation::Animation> {
    let source = surface.source.as_ref()?;
    let effect = surface.effect.unwrap_or(canvas::Effect::Sweep);
    let (rows, cols) = found.kind.key_layout();
    let (size, _) = found.kind.key_image_format().size;
    let background = surface
        .style(0.0, effect)
        .map(|style| style.background)
        .unwrap_or(image::Rgb([8, 9, 12]));

    match pult::animation::Animation::load(
        source,
        surface.mapping_for(effect),
        cols as u32,
        rows as u32,
        size as u32,
        surface.fps,
        surface.fit,
        surface.rotate,
        background,
    ) {
        Ok(animation) => {
            println!(
                "Anim    : {}, {} frames, {:.1}s",
                source.display(),
                animation.frames(),
                animation.duration().as_secs_f32()
            );
            Some(animation)
        }
        Err(e) => {
            // A bad file leaves the surface on its effect, or on nothing:
            // never on a dead dock.
            eprintln!("animation {} will not load: {e:#}", source.display());
            None
        }
    }
}

fn animation_for<'a>(
    loaded: &'a mut Option<(String, pult::animation::Animation)>,
    state: &State,
    scene_name: &str,
    found: &device::Found,
) -> Option<&'a pult::animation::Animation> {
    let source = state
        .config
        .scene(scene_name)
        .and_then(|scene| scene.canvas())
        .and_then(|surface| surface.source.clone())?;

    let key = format!("{scene_name}:{}", source.display());
    if loaded.as_ref().is_none_or(|(held, _)| held != &key) {
        let surface = state.config.scene(scene_name).and_then(|s| s.canvas())?;
        match decode(surface, found) {
            Some(animation) => *loaded = Some((key, animation)),
            None => {
                *loaded = None;
                return None;
            }
        }
    }

    loaded.as_ref().map(|(_, animation)| animation)
}

/// Spreads one still picture across the whole dock.
///
/// Used for the frame the dock will hold while the Mac sleeps: the image is
/// scaled to cover the canvas, cropped to it, and cut into tiles. Drawn in
/// physical geometry, because a picture is a shape and shapes must survive the
/// seams.
fn paint_image(device: &Ajazz, found: &device::Found, path: &std::path::Path) -> Result<()> {
    let (rows, cols) = found.kind.key_layout();
    let (key, _) = found.kind.key_image_format().size;
    let mut canvas = Canvas::new(
        canvas::Mapping::Physical,
        cols as u32,
        rows as u32,
        key as u32,
    );

    let picture = image::open(path)
        .with_context(|| format!("reading {}", path.display()))?
        .resize_to_fill(
            canvas.width(),
            canvas.height(),
            image::imageops::FilterType::Lanczos3,
        )
        .to_rgb8();

    canvas.image_mut().copy_from_slice(&picture);

    for index in 0..canvas.keys().min(found.kind.display_key_count() as u32) {
        let tile = image::DynamicImage::ImageRgb8(canvas.tile(index));
        device
            .set_button_image(index as u8, tile)
            .with_context(|| format!("sending sleep tile {index}"))?;
    }

    device.flush().context("flushing the sleep picture")?;
    Ok(())
}

/// Draws one frame of a scene that paints across the whole dock.
///
/// The keys keep whatever they are bound to, a canvas replaces the picture,
/// not the press.
fn paint_canvas(
    device: &Ajazz,
    surface: &Surface,
    found: &device::Found,
    time: f32,
    animation: Option<&pult::animation::Animation>,
) -> Result<()> {
    // A file of your own takes precedence over a built-in effect: it is the
    // more specific thing to have asked for.
    if let Some(animation) = animation {
        for (index, tile) in animation.at(time).tiles.iter().enumerate() {
            if index >= found.kind.display_key_count() as usize {
                break;
            }
            device
                .set_button_image(index as u8, image::DynamicImage::ImageRgb8(tile.clone()))
                .with_context(|| format!("sending animation tile {index}"))?;
        }
        device.flush().context("flushing animation")?;
        return Ok(());
    }

    let effect = surface.effect.unwrap_or(canvas::Effect::Sweep);
    let mapping = surface.mapping_for(effect);
    let (rows, cols) = found.kind.key_layout();
    let (key, _) = found.kind.key_image_format().size;

    let style = surface.style(time, effect)?;
    let mut canvas = Canvas::new(mapping, cols as u32, rows as u32, key as u32);
    canvas::draw(effect, &mut canvas, time, &style);

    for index in 0..canvas.keys().min(found.kind.display_key_count() as u32) {
        let tile = image::DynamicImage::ImageRgb8(canvas.tile(index));
        device
            .set_button_image(index as u8, tile)
            .with_context(|| format!("sending canvas tile {index}"))?;
    }

    device.flush().context("flushing canvas")?;
    Ok(())
}

/// Shows the output level across the whole dock, briefly.
fn paint_meter(
    device: &Ajazz,
    found: &device::Found,
    sound: pult::sound::Sound,
    silence: bool,
) -> Result<()> {
    let (rows, cols) = found.kind.key_layout();
    let (key, _) = found.kind.key_image_format().size;

    // Packed, not physical. A quarter of a physical canvas lies under the
    // plastic, so a level that crossed a seam would move a long way without
    // the picture changing and then jump. Packed is every visible pixel and
    // nothing else, which is what "a travelling front at constant speed" is
    // for: one percent of volume moves the edge by the same amount wherever
    // it is.
    let mut canvas = Canvas::new(canvas::Mapping::Packed, cols as u32, rows as u32, key as u32);
    let tint = image::Rgb([77, 163, 255]);
    let background = image::Rgb([10, 12, 16]);

    // Two events, two pictures, because they answer different questions. The
    // bar says how loud and cannot say "off": a muted dock and a quiet one
    // are the same bar. The glyph says on or off and cannot say how loud.
    // Drawing both at once was tried, and six speakers swamp a thin bar.
    if silence {
        // Physical here, not packed. This is a shape, and a shape keeps its
        // proportions only when the gaps it crosses are part of the geometry.
        canvas = Canvas::new(canvas::Mapping::Physical, cols as u32, rows as u32, key as u32);
        canvas::sound(&mut canvas, sound.muted, background);
    } else {
        canvas::meter(&mut canvas, sound.level, sound.muted, tint, background);
    }

    for index in 0..canvas.keys().min(found.kind.display_key_count() as u32) {
        device
            .set_button_image(index as u8, image::DynamicImage::ImageRgb8(canvas.tile(index)))
            .with_context(|| format!("sending meter tile {index}"))?;
    }
    device.flush().context("flushing the meter")?;
    Ok(())
}

/// The surface the dock is currently painting, if it is painting one at all.
///
/// A trial wins over the scene: while the editor is trying something out, that
/// is what the dock shows and what its clock must follow.
fn painting<'a>(
    state: &'a State,
    scene: &str,
    trying: Option<&'a (Surface, Instant)>,
) -> Option<&'a Surface> {
    if let Some((surface, _)) = trying {
        return Some(surface);
    }
    state.config.scene(scene).and_then(|scene| scene.canvas())
}

/// The frame clock and the phase rate for whatever is on the dock.
///
/// Two numbers, because they are different things and conflating them is what
/// made the speed knob jump the picture: `interval` is how often a frame goes
/// on the wire, `speed` is how fast the phase behind it grows.
fn clock(surface: Option<&Surface>) -> (Duration, f32) {
    match surface {
        Some(surface) => {
            let effect = surface.effect.unwrap_or(canvas::Effect::Sweep);
            let fps = f32::from(surface.fps_for(effect)).max(1.0);
            (Duration::from_secs_f32(1.0 / fps), surface.speed())
        }
        // A scene of six separate keys has nothing with a frame rate of its
        // own; the press flash is all that moves, and 15 is plenty for it.
        None => (FRAME_INTERVAL, 1.0),
    }
}

/// Renders a key, falling back to a plain one when its art will not draw.
///
/// A missing icon or a malformed colour is a mistake in the config; losing the
/// dock over it would be a far worse answer than showing a bare label.
fn draw(state: &State, key: &Key, frame: Frame, scene: &str, index: u8) -> DynamicImage {
    let view = key.view(state.view_of(scene, index));
    let drawn = state.renderer.reading(
        &view,
        &state.bindings(),
        SystemTime::now(),
        state.hour,
        frame,
    );

    match drawn {
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

/// The key as the daemon can draw it now, with every template filled in.
fn resolved(state: &State, key: &Key, scene: &str, index: u8) -> Key {
    let view = key.view(state.view_of(scene, index));
    pult::render::fill(&view, &state.bindings(), SystemTime::now(), state.hour)
}

/// Resolves a key's reading as the daemon sees it this moment.
fn readout_for(state: &State, key: &Key, scene: &str, index: u8) -> Readout {
    let view = key.view(state.view_of(scene, index));
    Readout::of(&view, &state.bindings(), SystemTime::now(), state.hour)
}

/// Everything a key currently shows, as one string.
///
/// The unit separator keeps the fields from running into one another, so a
/// caption ending in a digit cannot look like a changed value.
fn output_of(state: &State, key: &Key, scene: &str, index: u8) -> String {
    if key.reads() {
        let r = readout_for(state, key, scene, index);
        return format!(
            "{}\u{1f}{}\u{1f}{:?}\u{1f}{}\u{1f}{:?}\u{1f}{}",
            r.value, r.caption, r.icon, r.icon_rotate, r.background.0, r.fresh
        );
    }
    let key = resolved(state, key, scene, index);
    format!(
        "{}\u{1f}{:?}\u{1f}{:?}",
        key.label, key.icon, key.icon_rotate
    )
}

/// Pushes the keys whose reading has changed, and nothing else.
///
/// Run every iteration, so a feed answering or a caption ageing reaches the
/// dock inside one read timeout without the 15 fps path ever starting. The
/// comparison is on the output: a host that answers every fifteen minutes with
/// the same number must not cost six HID writes, and a dock that redraws for
/// nothing is a dock that feels busy.
fn refresh(
    device: &Ajazz,
    state: &State,
    scene_name: &str,
    page: usize,
    display_keys: u8,
) -> Result<()> {
    let Some(scene) = state.config.scene(scene_name) else {
        return Ok(());
    };
    if scene.canvas().is_some() {
        return Ok(());
    }

    let per_page = display_keys as usize;
    let marker = marker(page, scene.pages(per_page));
    let hour = state.scrub_marker(scene_name);
    let mut drawn = false;

    for (index, key) in scene.page(page, per_page).iter().enumerate() {
        let index = index as u8;
        if !key.live() {
            continue;
        }

        let output = output_of(state, key, scene_name, index);
        let slot = (scene_name.to_string(), index);
        if state.painted.borrow().get(&slot) == Some(&output) {
            continue;
        }

        let frame = Frame {
            pages: marker,
            hour,
            ..Frame::at(0.0)
        };
        let image = draw(state, key, frame, scene_name, index);
        device
            .set_button_image(index, image)
            .with_context(|| format!("sending reading for key {index}"))?;
        state.painted.borrow_mut().insert(slot, output);
        drawn = true;
    }

    if drawn {
        device.flush().context("flushing readings")?;
    }
    Ok(())
}

/// Whether two configs ask for different feeds.
///
/// Compared by their written form because a `Feed` carries no equality of its
/// own, and restarting pollers that have not changed would throw away every
/// sample on every save.
fn feeds_differ(before: &Config, after: &Config) -> bool {
    let written = |config: &Config| toml::to_string(&config.feeds).unwrap_or_default();
    written(before) != written(after)
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
    found: &device::Found,
    animation: Option<&pult::animation::Animation>,
) -> Result<bool> {
    let Some(scene) = state.config.scene(scene_name) else {
        return Ok(true);
    };

    if let Some(surface) = scene.canvas() {
        paint_canvas(device, surface, found, time, animation)?;
        return Ok(pressed.is_some_and(|(_, at)| at.elapsed() >= PRESS_FLASH));
    }

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

        let frame = Frame {
            time,
            press,
            pages,
            hour: state.scrub_marker(scene_name),
        };
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
    /// The output changed; show it. The flag says whether the change was the
    /// mute, because that question wants a different picture from "how loud".
    Sound(pult::sound::Sound, bool),
    Page(usize),
    /// A readout was pressed: show its next reading.
    Cycle(u8),
    /// A knob moved the forecast.
    Scrub(Hour),
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

    // A readout's press changes what it shows. Checked before the action table
    // because such a key has no action to run: validation refuses one, so a
    // press has exactly one meaning.
    if let Event::ButtonDown(index) = event {
        if index < display_keys {
            let reads = scene
                .page(page, per_page)
                .get(index as usize)
                .is_some_and(Key::reads);
            if reads {
                return Ok(Some(Step::Cycle(index)));
            }
        }
    }

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
                Ok(Outcome::Sound(sound)) => Ok(Some(Step::Sound(sound, false))),
                Ok(Outcome::Muted(sound)) => Ok(Some(Step::Sound(sound, true))),
                Ok(Outcome::Scrub(hour)) => Ok(Some(Step::Scrub(hour))),
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
    trying: &mut Option<(Surface, Instant)>,
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
            // The synonyms travel with the names: the picker searches by
            // meaning, and it is the only thing that needs them.
            let tags: serde_json::Value =
                serde_json::from_str(pult::icons::TAGS_JSON).unwrap_or(serde_json::Value::Null);
            reply.answer(json!({
                "ok": true,
                "icons": pult::icons::names(),
                "tags": tags,
            }));
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
            // Through `reading`, not `key_frame`: the editor is showing a key
            // somebody is still typing, and a preview that drew the template
            // instead of the number would be a preview of the wrong thing.
            let now = SystemTime::now();
            let bindings = state.bindings();
            match Renderer::new(state.config.font.as_deref(), size)
                .and_then(|r| r.reading(&key, &bindings, now, state.hour, frame))
                .and_then(|image| encode_png(&image))
            {
                Ok(png) => reply.ok(json!({ "png": png })),
                Err(e) => reply.fail(format!("{e:#}")),
            }
            Ok(false)
        }

        Request::RenderKeys { keys, size, pages } => {
            let size = size.map_or_else(|| state.renderer.size(), |s| (s, s));
            let renderer = Renderer::new(state.config.font.as_deref(), size)?;
            let frame = Frame {
                pages,
                ..Frame::default()
            };

            let now = SystemTime::now();
            let bindings = state.bindings();
            let mut pngs = Vec::with_capacity(keys.len());
            for key in &keys {
                match renderer
                    .reading(key, &bindings, now, state.hour, frame)
                    .and_then(|image| encode_png(&image))
                {
                    Ok(png) => pngs.push(serde_json::Value::String(png)),
                    // One unrenderable key must not cost the whole page.
                    Err(_) => pngs.push(serde_json::Value::Null),
                }
            }

            reply.ok(json!({ "pngs": pngs }));
            Ok(false)
        }

        Request::IconSheet { names, size, color } => {
            let size = size.unwrap_or(64);
            let renderer = Renderer::new(state.config.font.as_deref(), (size, size))?;
            let color = color.unwrap_or_else(|| "#f5f5f5".to_string());

            let wanted: Vec<String> = names.unwrap_or_else(|| {
                pult::icons::names().into_iter().map(str::to_string).collect()
            });

            let mut sheet = serde_json::Map::new();
            for name in wanted {
                let key = Key {
                    icon: Some(name.clone()),
                    icon_color: Some(color.clone()),
                    color: Some("#1c1f26".to_string()),
                    ..Key::default()
                };
                if let Ok(png) = renderer
                    .key_frame(&key, Frame::default())
                    .and_then(|image| encode_png(&image))
                {
                    sheet.insert(name, serde_json::Value::String(png));
                }
            }

            reply.ok(json!({ "icons": sheet }));
            Ok(false)
        }

        Request::PreviewCanvas {
            surface,
            frames,
            fps,
        } => {
            let (rows, cols) = found.kind.key_layout();
            let (key, _) = found.kind.key_image_format().size;
            let geometry = (cols as u32, rows as u32, key as u32);

            // Rendering sixty frames costs tens of milliseconds, and this loop
            // owes the dock a frame every 66. So the reply is handed to a
            // thread and answered from there.
            std::thread::spawn(move || match render_preview(*surface, geometry, frames, fps) {
                Ok(value) => reply.ok(value),
                Err(e) => reply.fail(format!("{e:#}")),
            });
            Ok(false)
        }

        Request::SetFeed {
            name,
            every,
            params,
        } => {
            // Picked up first. This writes the whole config back from
            // memory, so an edit made to the file since the last reload would
            // be thrown away by a change to one feed's interval.
            state.reload_if_changed();

            let changed = {
                let Some(feed) = state.config.feeds.get_mut(&name) else {
                    reply.fail(format!("no feed called {name:?}"));
                    return Ok(false);
                };
                if let Some(every) = every {
                    feed.every = every;
                }
                if let Some(params) = params {
                    feed.params = params;
                }
                // Checked before it is written. A unit nobody honours saved to
                // disk and silently ignored is the worst of both.
                if let Err(e) = feed.check() {
                    reply.fail(format!("{e:#}"));
                    return Ok(false);
                }
                feed.clone()
            };

            if let Err(e) = state.config.save(&state.path) {
                reply.fail(format!("{e:#}"));
                return Ok(false);
            }
            state.stamp = modified(&state.path);
            state.restart_feeds();
            println!("Feed    : {name} every {}", changed.every);
            reply.ok(json!({ "feed": name }));
            Ok(false)
        }

        Request::SetPlace { place } => {
            match feed::write_places(&place) {
                Ok(path) => {
                    println!("Place   : {} values in {}", place.len(), path.display());
                    // Restarted rather than nudged: the URL a poller is
                    // holding was built from the old coordinates, and the
                    // thread has no way of being told the address moved.
                    state.restart_feeds();
                    reply.ok(json!({ "path": path }));
                }
                Err(e) => reply.fail(format!("{e:#}")),
            }
            Ok(false)
        }

        Request::Feeds { name } => {
            // Polling on request happens here, on the loop's own thread. It is
            // one curl with an eight-second ceiling, and the alternative, a
            // thread writing into the same bindings the pollers use, buys
            // nothing for a button somebody pressed once.
            if let Some(name) = name.as_deref() {
                match state.config.feeds.get(name) {
                    Some(feed) => {
                        let polled = feed
                            .target(&state.places)
                            .and_then(|target| feed::poll(feed, &target, SystemTime::now()));
                        match polled {
                            Ok(sample) => state.bindings().put(name, sample),
                            Err(e) => state.bindings().fail(name, format!("{e:#}")),
                        }
                    }
                    None => {
                        reply.fail(format!("no feed called {name:?}"));
                        return Ok(false);
                    }
                }
            }

            let now = SystemTime::now();
            let bindings = state.bindings();
            let feeds: Vec<_> = state
                .config
                .feeds
                .iter()
                .map(|(name, feed)| {
                    let sample = bindings.sample(name);
                    json!({
                        "name": name,
                        "kind": feed.kind,
                        "source": feed.url.clone().or_else(|| feed.run.clone()),
                        "every": feed.every,
                        "stale_after": feed.stale_after,
                        "params": feed.params,
                        // Seconds, not a sentence: the app writes the words,
                        // in whichever of its two languages is showing.
                        "age": bindings.age(name, now).map(|age| age.as_secs()),
                        "stale": bindings.is_stale(name, now),
                        "error": bindings.error(name),
                        "fields": sample.map(|sample| {
                            sample
                                .fields
                                .iter()
                                .map(|(field, datum)| (field.clone(), datum.as_text()))
                                .collect::<std::collections::BTreeMap<_, _>>()
                        }),
                        "series": sample.map(|sample| {
                            sample
                                .series
                                .iter()
                                .map(|(field, series)| (field.clone(), series.values.len()))
                                .collect::<std::collections::BTreeMap<_, _>>()
                        }),
                    })
                })
                .collect();

            reply.ok(json!({
                "feeds": feeds,
                // The parameters this daemon knows how to offer as a control.
                // Shipped from here for the same reason the knob table is: a
                // list of pickers written into the app outlives the daemon it
                // was written against, and then offers a choice nothing reads.
                "known": feed::known_params()
                    .iter()
                    .map(|known| {
                        json!({
                            "name": known.name,
                            "options": known.options,
                            "kind": known.kind,
                        })
                    })
                    .collect::<Vec<_>>(),
                // Intervals worth offering, by the kind of thing being asked.
                // A machine can be read every second; somebody else's host
                // cannot.
                "intervals": json!({
                    "http": feed::intervals(pult::feed::FeedKind::Http),
                    "shell": feed::intervals(pult::feed::FeedKind::Shell),
                }),
                // Where the readings are being asked for, so the app can tell
                // the difference between "no coordinates yet" and "the host is
                // down" without guessing.
                "places": state.places,
                "hour": state.hour,
            }));
            Ok(false)
        }

        Request::Effects => {
            reply.ok(json!({
                "effects": canvas::Effect::all()
                    .iter()
                    .map(|effect| json!({
                        "name": effect.name(),
                        "title": effect.title(),
                        "sentence": effect.sentence(),
                        "fps": effect.fps(),
                        "mapping": effect.mapping(),
                        "period": effect.period(),
                        "direction": effect.dir(),
                        // The names with their rows attached: the editor draws
                        // one control per entry and needs no table of its own.
                        "knobs": effect
                            .knobs()
                            .iter()
                            .filter_map(|name| canvas::knob(name))
                            .collect::<Vec<_>>(),
                    }))
                    .collect::<Vec<_>>(),
            }));
            Ok(false)
        }

        Request::EffectStrips { frames } => {
            let (rows, cols) = found.kind.key_layout();
            let (key, _) = found.kind.key_image_format().size;
            let geometry = (cols as u32, rows as u32, key as u32);
            let wanted = frames.unwrap_or(10).clamp(2, 30);

            std::thread::spawn(move || {
                let mut strips = serde_json::Map::new();
                for effect in canvas::Effect::all() {
                    let surface = pult::config::Surface {
                        kind: pult::config::SurfaceKind::Canvas,
                        effect: Some(effect),
                        ..Default::default()
                    };
                    match render_preview(surface, geometry, Some(wanted), None) {
                        Ok(value) => {
                            strips.insert(effect.name().to_string(), value);
                        }
                        Err(_) => continue,
                    }
                }
                reply.ok(json!({ "strips": strips }));
            });
            Ok(false)
        }

        Request::TryCanvas { surface, seconds } => {
            let window = Duration::from_secs_f32(seconds.unwrap_or(20.0).clamp(1.0, 120.0));
            *trying = Some((*surface, Instant::now() + window));
            reply.ok(json!({ "trying": true, "seconds": window.as_secs_f32() }));
            Ok(false)
        }

        Request::TryStop => {
            let was = trying.take().is_some();
            reply.ok(json!({ "stopped": was }));
            Ok(was)
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

        Request::BootLogo { path, color } => {
            // The only thing the dock keeps when it is unplugged, and keeps
            // showing, since it is the panel's own backdrop and nothing here
            // sends it again after the one write.
            let picture = match &path {
                Some(path) => image::open(path).map_err(anyhow::Error::from),
                None => {
                    // The device's own logo size, not a guess: a fill of the
                    // wrong shape would be scaled and could leave an edge.
                    let (width, height) = found
                        .kind
                        .boot_logo_size()
                        .unwrap_or((320, 240));
                    let fill = color
                        .as_deref()
                        .map(pult::render::parse_color)
                        .transpose()?
                        .unwrap_or(image::Rgb([0, 0, 0]));
                    Ok(image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
                        width as u32,
                        height as u32,
                        fill,
                    )))
                }
            };

            match picture
                .and_then(|image| device.set_logo_image(image).map_err(anyhow::Error::from))
            {
                Ok(()) => reply.ok(json!({ "written": true, "cleared": path.is_none() })),
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
