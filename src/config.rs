//! Configuration: scenes, what each key does, and which app selects which scene.

use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use image::Rgb;
use serde::{Deserialize, Serialize};

use crate::canvas::{k, Style};
use crate::feed::Feed;

/// Starter config written on first run, so the daemon has something to show.
pub const EXAMPLE: &str = include_str!("../config.example.toml");

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Backlight, 0-100.
    #[serde(default = "default_brightness")]
    pub brightness: u8,
    /// How often to ask macOS which app is in front.
    #[serde(default = "default_poll_ms")]
    pub poll_ms: u64,
    /// TrueType font for key labels; a system font is used when unset.
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font: Option<PathBuf>,
    /// Light a key up briefly when it is pressed.
    #[serde(default = "default_press_feedback")]
    pub press_feedback: bool,
    /// Scene to fall back to when no scene claims the frontmost app.
    pub default: String,
    /// One scene, held there whatever is in front.
    ///
    /// Absent means what the dock has always done: follow the frontmost
    /// application. One optional field rather than a flag beside a name,
    /// because a flag saying "fixed" next to an empty name is a state that
    /// has to be given a meaning, and every meaning is a surprise to someone.
    ///
    /// It does not touch the screensaver. Resting when nobody is there is a
    /// separate question with its own block, and folding the two together
    /// would mean one switch quietly doing two things.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<String>,
    /// What the dock does when nobody has touched the Mac for a while.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idle: Option<Idle>,
    /// Numbers fetched from somewhere else, by name. A key reads one through
    /// a template, so a page of live data costs config rather than code.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub feeds: BTreeMap<String, Feed>,
    pub scenes: BTreeMap<String, Scene>,
}

/// The idle screen.
///
/// One block, never a flag per scene: two scenes both claiming the idle slot is
/// an ambiguity that only ever becomes a bug report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Idle {
    /// How long since the last keyboard or pointer event: `30s`, `3m`, `1h`.
    pub after: String,
    /// The scene to show. Usually a canvas, but any scene will do.
    pub scene: String,
    /// Or a playlist, which wins over `scene`. Each member is a whole scene, so
    /// every member keeps its own effect, colours, geometry and frame rate,
    /// and each can be judged on its own page before it goes in here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scenes: Vec<String>,
    /// How long each member runs. Five minutes is long enough to stop feeling
    /// like a slideshow.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hold: Option<String>,
    /// Seconds of cross-dissolve between members. A hard cut in peripheral
    /// vision on a desk reads as a fault, so the default is not zero.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fade: Option<f32>,
    /// Seconds to ramp `opacity` from nothing when the screensaver starts, so
    /// it arrives instead of appearing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fade_in: Option<f32>,
    /// What counts as waking. `dock` is what you want when you are reading a
    /// second screen and would rather the dock kept painting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wake_on: Option<WakeOn>,
    /// Dimmer than working brightness, and never below a quarter: the backlight
    /// shifts colour at the bottom of its range.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brightness: Option<u8>,
    /// Follow the Mac's display to sleep.
    ///
    /// Off by default: the point of an idle screen is that it keeps running
    /// when you look away. Turn it on if the dock lighting a dark room at
    /// night bothers you.
    ///
    /// This is about the *display* sleeping while the Mac stays awake. Nothing
    /// can be done about full system sleep: the daemon is suspended with
    /// everything else, so the dock holds its last frame until the Mac wakes.
    #[serde(default)]
    pub dark_when_display_sleeps: bool,
    /// Waking the dock with a key should not also fire what that key does.
    #[serde(default = "yes")]
    pub swallow_first_press: bool,
    /// The picture to leave on the dock while the Mac sleeps.
    ///
    /// Nothing here can animate: the daemon is frozen along with the rest of
    /// the Mac, so whatever was sent last is what stays on the keys until it
    /// wakes. This is that last frame, a PNG or JPEG, drawn across the whole
    /// dock. Absent means the dock simply keeps whatever it was showing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sleep_image: Option<PathBuf>,
}

fn yes() -> bool {
    true
}

fn is_default_fit(fit: &crate::animation::Fit) -> bool {
    *fit == crate::animation::Fit::default()
}

fn is_zero(value: &u16) -> bool {
    *value == 0
}

impl Idle {
    pub fn after(&self) -> Duration {
        crate::idle::parse_duration(&self.after).unwrap_or(Duration::from_secs(180))
    }

    /// Brightness while idle, floored so the colours stay honest.
    pub fn brightness(&self) -> u8 {
        self.brightness.unwrap_or(35).clamp(25, 100)
    }
}

/// What counts as activity while the dock is resting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum WakeOn {
    /// A keystroke, the pointer, or a press on the dock.
    #[default]
    Any,
    /// Only a press on the dock itself.
    Dock,
}

impl Idle {
    /// The playlist, or the single scene as a playlist of one. Callers then
    /// have one shape to handle instead of two.
    pub fn playlist(&self) -> Vec<String> {
        if self.scenes.is_empty() {
            vec![self.scene.clone()]
        } else {
            self.scenes.clone()
        }
    }

    pub fn hold(&self) -> Duration {
        self.hold
            .as_deref()
            .and_then(crate::idle::parse_duration)
            .filter(|held| !held.is_zero())
            .unwrap_or(Duration::from_secs(300))
    }

    pub fn fade(&self) -> f32 {
        self.fade.unwrap_or(2.5).clamp(0.0, 30.0)
    }

    pub fn fade_in(&self) -> f32 {
        self.fade_in.unwrap_or(1.5).clamp(0.0, 30.0)
    }

    pub fn wake_on(&self) -> WakeOn {
        self.wake_on.unwrap_or_default()
    }
}

/// What a scene paints with.
///
/// Absent means `keys`, so every configuration written before this existed
/// keeps its meaning exactly. Every field below is optional for the same
/// reason: unset means the effect's own choice, and the daemon writes back
/// only what was actually set, which is what keeps the file readable by hand.
///
/// Deliberately flat, no nested tables anywhere in here. `toml` refuses to
/// emit a value after a table within one struct, and `config_survives_a_round_trip`
/// is the test that catches it. Arrays of numbers are values, not tables, so
/// `origin` and `lobes` are safe.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Surface {
    #[serde(default)]
    pub kind: SurfaceKind,
    /// Which motion a canvas runs. Ignored when `source` names a file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect: Option<crate::canvas::Effect>,
    /// An animation of your own, instead of a built-in effect.
    ///
    /// A GIF, an animated PNG, an animated WebP, a folder of numbered PNG or
    /// JPEG frames, or one still picture. Decoded once when the scene is shown;
    /// video formats are not accepted, and SVG animation is SMIL, which the
    /// renderer does not implement.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<PathBuf>,
    /// How a source that is not the canvas's shape is made to fit it.
    ///
    /// The dock is always landscape, 212x136, about 1.56:1, so a portrait
    /// animation has to lose its edges or gain bars at the sides. `cover`
    /// crops, `contain` keeps all of it, `stretch` distorts.
    #[serde(default, skip_serializing_if = "is_default_fit")]
    pub fit: crate::animation::Fit,
    /// Quarter turns applied before fitting, for a clip filmed sideways.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub rotate: u16,
    /// Repeat the source instead of fitting it. With `pan` this is an endless
    /// scrolling wallpaper, which is the most reliable way to run your own art
    /// on a dock with seams: nothing has an edge for a bezel to cut.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tile: Option<bool>,
    /// Pixels per second along `direction`, for a source. Setting this is what
    /// turns a still picture into something the seams cannot spoil; 6 to 20 is
    /// calm.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pan: Option<f32>,

    // --- colour ------------------------------------------------------------
    /// The hottest pixels.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// The second stop. Unset means the first lightened by 55%, so a
    /// two-colour effect looks deliberate without anyone choosing twice.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color2: Option<String>,
    /// The fill under everything. A near-black rather than pure black: a truly
    /// black dock beside lit plastic reads as broken.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    /// Seconds for one slow drift between the two stops; 0 or unset is off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_cycle: Option<f32>,

    // --- motion ------------------------------------------------------------
    /// The only clock. `tau` advances by `dt * speed`, so changing this never
    /// makes the picture jump, it changes how fast the phase grows, not where
    /// the phase currently is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<f32>,
    /// Unset means the effect's own axis.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direction: Option<crate::canvas::Dir>,
    /// `bounce` turns a sweep into a scanning sentry and rain into a fish tank.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle: Option<crate::canvas::Cycle>,

    // --- size and amount ---------------------------------------------------
    /// Multiplies every length and divides every spatial frequency. This is
    /// the knob that decides whether a feature is wider than the 16 px seam.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<f32>,
    /// Multiplies the count: bars, rings, streaks, stars, blobs, bodies.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub density: Option<f32>,
    /// 0 a hard edge, 1 feathered across the whole half-width.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub softness: Option<f32>,
    /// Fractions of the canvas, for `pulse` and `warp`. The middle is the dead
    /// centre of the horizontal seam, so a ring is born behind plastic and
    /// emerges already sixteen pixels across.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<[f32; 2]>,

    // --- light -------------------------------------------------------------
    /// The master fade, which the idle ramp rides. Not the backlight.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f32>,
    /// The only input to the catalogue's hash. The picture is a pure function
    /// of `(tau, seed)`, so a repaint or a reload resumes where the eye left
    /// off; change this for a different arrangement with the same character.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed: Option<u32>,

    // --- geometry, clock, manners -------------------------------------------
    /// Override the geometry the effect would choose for itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mapping: Option<crate::canvas::Mapping>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps: Option<u8>,
    /// Hold the last frame after this long, so motion under your hands is not
    /// a distraction in a scene you actually work in. Absent or `0s` never
    /// stops, which is what a screensaver wants.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_after: Option<String>,
    /// Paint one still frame when macOS asks for less motion.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reduce_motion: Option<bool>,

    // --- the ones belonging to one effect only ------------------------------
    /// `sweep`: tilts the bar; about ±0.3 is a diagonal wipe.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shear: Option<f32>,
    /// `wave`: 0 a line, 0.5 liquid in a tank.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill: Option<f32>,
    /// `aurora`: 0 a smooth field, 3 to 5 soft posterised steps.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bands: Option<u8>,
    /// `rain`: sideways drift per step. Past about ±0.4 set
    /// `mapping = "physical"`, or a steep slant kinks at every seam.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wind: Option<f32>,
    /// `orbit`: 1,1 an ellipse; 3,2 a knot; 2,1 a figure of eight.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lobes: Option<[u8; 2]>,
    /// `orbit` and `warp`: seconds of the past drawn. At 0 the head crosses a
    /// seam invisibly, which is the one setting that can break those two.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trail: Option<f32>,
    /// `warp`: 1 a drift, 2.4 perspective, 4 a violent jump.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exponent: Option<f32>,
    /// `lava`: low merges everything, high separates islands.
    ///
    /// 1.0 is where a blob ends at the radius `scale` gives it. Below that it
    /// reaches further than its radius, at 0.4 it reaches 1.58 times as far,
    /// which with five blobs is the whole dock lit and nothing to look at.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub threshold: Option<f32>,
    /// `ember`: how far up the span the flame reaches.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<f32>,
    /// `ember`: dissolve the tip into the background.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub smoke: Option<f32>,
    /// `breathe`: which envelope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<crate::canvas::Shape>,
    /// `breathe`: the level at the bottom of a breath. Keep it above zero so
    /// the dock never looks switched off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub floor: Option<f32>,
}

/// The defaults, in the one place they are allowed to live.
///
/// Everything here is `clamp`, never `bail`: a number out of range is not
/// worth losing the dock over, and a person dragging a slider past the end
/// should see the end, not an error. `validate()` still refuses the two things
/// that cannot be guessed, an unparseable colour and a canvas that names
/// neither an effect nor a file.
impl Surface {
    const COLOR: Rgb<u8> = Rgb([80, 160, 255]);
    const BACKGROUND: Rgb<u8> = Rgb([8, 9, 12]);

    /// Resolves every knob for one frame. The only constructor of `Style`, so
    /// no `unwrap_or` for any of these values exists anywhere else.
    pub fn style(&self, tau: f32, effect: crate::canvas::Effect) -> Result<Style> {
        let c = self.parse(self.color.as_deref(), "color")?.unwrap_or(Self::COLOR);
        let second = match self.parse(self.color2.as_deref(), "color2")? {
            Some(colour) => colour,
            None => crate::canvas::mix(c, Rgb([255, 255, 255]), 0.55),
        };
        let background = self
            .parse(self.background.as_deref(), "background")?
            .unwrap_or(Self::BACKGROUND);

        // A slow drift between the two stops, in tau-seconds like every other
        // period here, so the speed knob carries the colour with it.
        let (c, second) = match self.color_cycle {
            Some(seconds) if seconds > 0.01 => {
                let u = 0.5 - 0.5 * (std::f32::consts::TAU * tau / seconds).cos();
                (
                    crate::canvas::mix(c, second, u),
                    crate::canvas::mix(second, c, u),
                )
            }
            _ => (c, second),
        };

        // Every number below comes from the knob table, which is also what
        // the editor is told the slider's ends are. One table, so a slider
        // cannot run past what the daemon will honour and look broken near
        // its end.
        let origin = k("origin").pair(self.origin);
        let lobes = k("lobes").pair(
            self.lobes
                .map(|lobes| [f32::from(lobes[0]), f32::from(lobes[1])]),
        );

        Ok(Style {
            c,
            k: second,
            background,
            opacity: k("opacity").number(self.opacity),
            softness: k("softness").number(self.softness),
            scale: k("scale").number(self.scale),
            density: k("density").number(self.density),
            dir: self.direction.unwrap_or_else(|| effect.dir()),
            cycle: self.cycle.unwrap_or_default(),
            origin,
            seed: k("seed").number(self.seed.map(|seed| seed as f32)) as u32,
            clear: true,
            shear: k("shear").number(self.shear),
            fill: k("fill").number(self.fill),
            bands: k("bands").count(self.bands),
            wind: k("wind").number(self.wind),
            lobes: (lobes.0.round() as u8, lobes.1.round() as u8),
            trail: k("trail").number(self.trail),
            exponent: k("exponent").number(self.exponent),
            threshold: k("threshold").number(self.threshold),
            height: k("height").number(self.height),
            smoke: k("smoke").number(self.smoke),
            shape: self.shape.unwrap_or_default(),
            floor: k("floor").number(self.floor),
        })
    }

    /// How fast `tau` grows. Not part of `Style`: no effect may read it, which
    /// is exactly what stops a speed change from moving the picture.
    pub fn speed(&self) -> f32 {
        k("speed").number(self.speed)
    }

    pub fn mapping_for(&self, effect: crate::canvas::Effect) -> crate::canvas::Mapping {
        self.mapping.unwrap_or_else(|| effect.mapping())
    }

    pub fn fps_for(&self, effect: crate::canvas::Effect) -> u8 {
        k("fps").count(Some(self.fps.unwrap_or_else(|| effect.fps())))
    }

    /// How long motion runs before the last frame simply stays. `None` means
    /// never stop.
    pub fn stop_after(&self) -> Option<Duration> {
        let text = self.stop_after.as_deref()?;
        crate::idle::parse_duration(text).filter(|held| !held.is_zero())
    }

    pub fn respects_reduce_motion(&self) -> bool {
        self.reduce_motion.unwrap_or(true)
    }

    fn parse(&self, text: Option<&str>, field: &str) -> Result<Option<Rgb<u8>>> {
        match text {
            Some(text) => Ok(Some(
                crate::render::parse_color(text)
                    .with_context(|| format!("surface {field} is not a colour: {text:?}"))?,
            )),
            None => Ok(None),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKind {
    /// Six keys, each its own picture. What every scene was until now.
    #[default]
    Keys,
    /// One drawing spanning the whole dock, cut into six.
    Canvas,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Scene {
    /// Bundle IDs this scene claims. A trailing `*` matches a prefix.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub apps: Vec<String>,
    /// The six keys with displays, in reading order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keys: Vec<Key>,
    /// The three keys without displays.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub buttons: Vec<Action>,
    /// The three encoders, left to right.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub encoders: Vec<Encoder>,
    /// What this scene paints with; absent means six separate keys.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub surface: Option<Surface>,
    /// How many hours ahead a knob bound to `hour` may walk this scene.
    ///
    /// Absent means as far as the feeds actually brought back, which is the
    /// honest default: a knob that can reach an hour nobody fetched is a knob
    /// that reaches an em dash.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hours: Option<usize>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Key {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    /// Background, `#RRGGBB`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Label colour; picked from the background when unset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_color: Option<String>,
    /// A bundled icon's name, or a path to an SVG or bitmap.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Icon colour; follows the label when unset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_color: Option<String>,
    /// Turns the icon, in degrees. A template, so an arrow can point at the
    /// wind rather than at a number somebody typed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_rotate: Option<String>,
    /// Movement to give the key while its scene is showing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animate: Option<Animation>,
    /// The reading this key shows, as a template: `{vreme.temp|round}°`.
    /// A key with a value draws the value large and the label not at all.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// The line under the value, which says what the value is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    /// A background chosen by the reading itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ramp: Option<Ramp>,
    /// The other things this key can show. Pressing it moves to the next and
    /// repaints that one key, which is 1.2 ms.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cycle: Vec<KeyView>,
    #[serde(flatten)]
    pub action: Action,
}

fn gather(text: &str, names: &mut Vec<String>) {
    for name in crate::values::feeds_named(text) {
        if !names.iter().any(|seen| seen == name) {
            names.push(name.to_string());
        }
    }
}

/// A colour chosen by a number, so the key's own background is a reading.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ramp {
    /// What to read, as `feed.field`.
    pub field: String,
    /// Breakpoints, each a value and a colour. Between two stops the colour is
    /// mixed; outside the ends it holds, because a temperature off the scale is
    /// still that end of the scale.
    pub stops: Vec<(f64, String)>,
}

impl Ramp {
    /// A ramp that cannot be read is refused rather than guessed: a colour is
    /// not a number to clamp, and stops out of order mix backwards.
    pub fn check(&self) -> Result<()> {
        if self.stops.is_empty() {
            bail!("a ramp on {:?} has no stops", self.field);
        }
        let mut last = f64::NEG_INFINITY;
        for (value, colour) in &self.stops {
            crate::render::parse_color(colour)
                .with_context(|| format!("in the ramp on {:?}", self.field))?;
            if *value < last {
                bail!(
                    "the ramp on {:?} steps back to {value} after {last}; stops run upwards",
                    self.field
                );
            }
            last = *value;
        }
        Ok(())
    }

    /// The colour this ramp gives `value`.
    ///
    /// Outside the ends it holds: a temperature past the last stop is still
    /// that end of the scale, and wrapping round to the cold colour would read
    /// as a fault.
    pub fn color(&self, value: f64) -> Option<Rgb<u8>> {
        let first = self.stops.first()?;
        if value <= first.0 {
            return crate::render::parse_color(&first.1).ok();
        }
        for pair in self.stops.windows(2) {
            let (low, high) = (&pair[0], &pair[1]);
            if value <= high.0 {
                let span = high.0 - low.0;
                let t = if span > 0.0 { (value - low.0) / span } else { 1.0 };
                let low = crate::render::parse_color(&low.1).ok()?;
                let high = crate::render::parse_color(&high.1).ok()?;
                return Some(crate::render::mix(low, high, t as f32));
            }
        }
        let last = self.stops.last()?;
        crate::render::parse_color(&last.1).ok()
    }
}

/// One of the things a key can show.
///
/// The reading travels as a whole: `value`, `caption` and `ramp` come from the
/// member and are not inherited, because a caption describes the number above
/// it and a ramp colours that number. Inheriting either is how a key ends up
/// labelling humidity as a temperature. Everything else, the label, the icon,
/// the colours, is the key's identity and stays put.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct KeyView {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ramp: Option<Ramp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_rotate: Option<String>,
}

impl Key {
    /// Whether this key is a readout rather than a button.
    ///
    /// A readout's press changes what it shows and fires no action: a key that
    /// both reports and acts is a key nobody dares to press.
    pub fn reads(&self) -> bool {
        self.value.is_some() || !self.cycle.is_empty()
    }

    /// Whether anything this key shows comes from a feed.
    ///
    /// Checked for a brace rather than by parsing: this runs for every key on
    /// every pass of the loop, and the answer is no for almost all of them.
    pub fn live(&self) -> bool {
        if self.reads() {
            return true;
        }
        // A ramp paints the background from a feed, so a key wearing one is a
        // reading even when it shows no number: a room tile that lights up when
        // the room is on, a door that goes red when it opens.
        if self.ramp.is_some() {
            return true;
        }
        if self.label.contains('{') {
            return true;
        }
        [&self.icon, &self.icon_rotate]
            .into_iter()
            .flatten()
            .any(|text| text.contains('{'))
    }

    /// How many things this key can show.
    pub fn views(&self) -> usize {
        self.cycle.len() + 1
    }

    /// Every feed this key reads: its cycle, its ramp and its templates.
    pub fn feeds(&self) -> Vec<String> {
        let mut names = Vec::new();
        for index in 0..self.views() {
            let view = self.view(index);
            for text in [&view.value, &view.caption, &view.icon, &view.icon_rotate]
                .into_iter()
                .flatten()
            {
                gather(text, &mut names);
            }
            if let Some(ramp) = &view.ramp {
                // A ramp names its field directly: the same grammar with the
                // braces left off.
                gather(&format!("{{{}}}", ramp.field), &mut names);
            }
        }
        names
    }

    /// The key as its `index`th view shows it, wrapping round.
    pub fn view(&self, index: usize) -> Key {
        let Some(overlay) = index
            .checked_rem(self.views())
            .and_then(|index| index.checked_sub(1))
            .and_then(|index| self.cycle.get(index))
        else {
            return self.clone();
        };

        Key {
            value: overlay.value.clone(),
            caption: overlay.caption.clone(),
            ramp: overlay.ramp.clone(),
            icon: overlay.icon.clone().or_else(|| self.icon.clone()),
            icon_rotate: overlay
                .icon_rotate
                .clone()
                .or_else(|| self.icon_rotate.clone()),
            ..self.clone()
        }
    }
}

impl Scene {
    /// The canvas this scene paints with, if it paints with one.
    pub fn canvas(&self) -> Option<&Surface> {
        self.surface
            .as_ref()
            .filter(|surface| surface.kind == SurfaceKind::Canvas)
    }

    /// Whether anything on `page` moves on its own, and so needs a redraw clock.
    pub fn is_animated(&self, page: usize, per_page: usize) -> bool {
        if self.canvas().is_some() {
            return true;
        }
        self.page(page, per_page)
            .iter()
            .any(|key| key.animate.is_some())
    }

    /// How many pages this scene fills, never fewer than one.
    pub fn pages(&self, per_page: usize) -> usize {
        self.keys.len().div_ceil(per_page.max(1)).max(1)
    }

    /// The keys shown on one page, which may be shorter than a full page.
    pub fn page(&self, page: usize, per_page: usize) -> &[Key] {
        let per_page = per_page.max(1);
        let start = (page * per_page).min(self.keys.len());
        let end = (start + per_page).min(self.keys.len());
        &self.keys[start..end]
    }
}

/// What an animated key does while its scene is on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Animation {
    /// The icon breathes: use it to draw the eye without shouting.
    Pulse,
    /// The icon turns: for anything that means "working".
    Spin,
    /// The background flashes: for anything that means "live" or "careful".
    Blink,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Encoder {
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub cw: Action,
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub ccw: Action,
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub press: Action,
}

/// What a key does. At most one field may be set.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Action {
    /// Application to bring up, by bundle ID or by name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// Shell command, run detached.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    /// Keystroke to send, e.g. `cmd+shift+4` or `f8`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shortcut: Option<String>,
    /// Scene to switch to by hand.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scene: Option<String>,
    /// Output volume change in percentage points, e.g. `-5`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume: Option<i32>,
    /// Silence the output: `toggle`, `on` or `off`.
    ///
    /// An action of its own rather than a keystroke. The mute key is F10, not
    /// F8, and sending either depends on how the keyboard is set up and needs
    /// permission to send keys at all, while setting the volume needs neither.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mute: Option<Mute>,
    /// Move through a scene's pages: `next`, `prev` or `first`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<Page>,
    /// Move the whole scene through the forecast: `next`, `prev` or `now`.
    ///
    /// Scene-wide and not per key: scrubbing one key out of six would leave
    /// five numbers from a different hour sitting beside it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hour: Option<Hour>,
    /// Rotate what the dock shows through a fixed list, one step per press.
    ///
    /// Each entry is a scene to pin, and an empty string is "follow the
    /// frontmost application" (no pin at all). The next step is read from the
    /// current pin, not remembered here, so the button stays right even when
    /// the pin was moved some other way, and it is the one place the dock can
    /// go back to following applications once something has been pinned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotate: Option<Vec<String>>,
}

/// Which hour the keys read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Hour {
    Next,
    Prev,
    Now,
}

/// What to do to the output mute.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mute {
    Toggle,
    On,
    Off,
}

/// Which page of a scene to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Page {
    Next,
    Prev,
    First,
}

impl Action {
    pub fn is_empty(&self) -> bool {
        self.count() == 0
    }

    fn count(&self) -> usize {
        usize::from(self.app.is_some())
            + usize::from(self.run.is_some())
            + usize::from(self.shortcut.is_some())
            + usize::from(self.scene.is_some())
            + usize::from(self.volume.is_some())
            + usize::from(self.mute.is_some())
            + usize::from(self.page.is_some())
            + usize::from(self.hour.is_some())
            + usize::from(self.rotate.is_some())
    }
}

fn default_brightness() -> u8 {
    70
}

fn default_poll_ms() -> u64 {
    300
}

fn default_press_feedback() -> bool {
    true
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = fs::read_to_string(path)
            .with_context(|| format!("reading config {}", path.display()))?;
        let mut config: Config = toml::from_str(&text)
            .with_context(|| format!("parsing config {}", path.display()))?;
        config.expand_paths();
        config.validate()?;
        Ok(config)
    }

    /// Rewrites every path in the file so a leading `~` means what it looks
    /// like it means.
    fn expand_paths(&mut self) {
        if let Some(font) = self.font.take() {
            self.font = Some(expand(&font));
        }
        if let Some(idle) = self.idle.as_mut() {
            if let Some(image) = idle.sleep_image.take() {
                idle.sleep_image = Some(expand(&image));
            }
        }
        for scene in self.scenes.values_mut() {
            if let Some(surface) = scene.surface.as_mut() {
                if let Some(source) = surface.source.take() {
                    surface.source = Some(expand(&source));
                }
            }
            for key in scene.keys.iter_mut() {
                // A bundled icon is a name, not a path; only a path can have a
                // tilde in front of it.
                if let Some(icon) = key.icon.as_ref().filter(|i| i.starts_with("~/")) {
                    key.icon = Some(expand(Path::new(icon)).to_string_lossy().into_owned());
                }
            }
        }
    }

    /// Rejects what would otherwise fail silently at runtime: a missing default
    /// scene, a key bound to two actions, a `scene` action pointing nowhere.
    /// Files the config names that are not there.
    ///
    /// Deliberately not part of `validate`. A renamed picture is not a reason
    /// to refuse a whole configuration and leave the dock dark, that trade
    /// was made once already for `sleep_image` and it was the wrong one. So
    /// this is a list to print, naming the scene and the path, at the moment
    /// the config is read rather than whenever that scene first comes up.
    pub fn missing_files(&self) -> Vec<String> {
        let mut missing = Vec::new();

        if let Some(image) = self.idle.as_ref().and_then(|idle| idle.sleep_image.as_ref()) {
            if !image.exists() {
                missing.push(format!(
                    "the sleep picture {} is not there; the dock will keep its last frame",
                    image.display()
                ));
            }
        }

        for (name, scene) in &self.scenes {
            for (index, key) in scene.keys.iter().enumerate() {
                for feed in key.feeds() {
                    if !self.feeds.contains_key(&feed) {
                        missing.push(format!(
                            "scene {name:?} key {index} reads feed {feed:?}, which is not \
                             configured; that key will show an em dash"
                        ));
                    }
                }
            }
        }

        for (name, scene) in &self.scenes {
            let Some(source) = scene.canvas().and_then(|surface| surface.source.as_ref()) else {
                continue;
            };
            if !source.exists() {
                missing.push(format!(
                    "scene {name:?} paints {}, which is not there; it will fall back to its effect",
                    source.display()
                ));
            }
        }

        missing
    }

    pub fn validate(&self) -> Result<()> {
        if !self.scenes.contains_key(&self.default) {
            bail!("default scene {:?} is not defined", self.default);
        }

        if let Some(pinned) = &self.pinned {
            if !self.scenes.contains_key(pinned) {
                bail!("pinned scene {pinned:?} is not defined");
            }
        }

        if let Some(idle) = &self.idle {
            // The playlist is checked member by member and names the one that
            // is wrong: "idle playlist" on its own sends you reading the file.
            for member in idle.playlist() {
                if !self.scenes.contains_key(&member) {
                    bail!("idle scene {member:?} is not defined");
                }
            }
            if crate::idle::parse_duration(&idle.after).is_none() {
                bail!("idle after {:?} is not a duration like 30s, 3m or 1h", idle.after);
            }
            if let Some(hold) = &idle.hold {
                if crate::idle::parse_duration(hold).is_none() {
                    bail!("idle hold {hold:?} is not a duration like 30s, 5m or 1h");
                }
            }
            // A missing sleep picture is not worth refusing the whole file
            // over: the dock would stop working over a renamed image. It is
            // reported when it is reached, and the dock keeps its last frame.
        }

        for (name, feed) in &self.feeds {
            feed.check()
                .with_context(|| format!("in feed {name:?}"))?;
        }

        for (name, scene) in &self.scenes {
            if scene.buttons.len() > 3 {
                bail!(
                    "scene {name:?} has {} buttons, the dock has 3",
                    scene.buttons.len()
                );
            }
            if scene.encoders.len() > 3 {
                bail!(
                    "scene {name:?} has {} encoders, the dock has 3",
                    scene.encoders.len()
                );
            }

            // A rotate that names a scene the config does not define would skip
            // a dead stop without saying why, so it is refused here. An empty
            // entry is "follow the frontmost application" and is always valid.
            let actions = scene
                .keys
                .iter()
                .map(|key| &key.action)
                .chain(scene.buttons.iter())
                .chain(
                    scene
                        .encoders
                        .iter()
                        .flat_map(|enc| [&enc.cw, &enc.ccw, &enc.press]),
                );
            for action in actions {
                if let Some(targets) = &action.rotate {
                    for target in targets {
                        if !target.is_empty() && !self.scenes.contains_key(target) {
                            bail!(
                                "scene {name:?} has a rotate step {target:?} \
                                 that is not a defined scene"
                            );
                        }
                    }
                }
            }

            if let Some(surface) = scene.canvas() {
                if surface.effect.is_none() && surface.source.is_none() {
                    bail!("scene {name:?} is a canvas but names neither effect nor source");
                }
                // Numbers out of range are clamped where they are read, but a
                // colour cannot be guessed, so it is still refused here.
                for colour in [&surface.color, &surface.color2, &surface.background]
                    .into_iter()
                    .flatten()
                {
                    crate::render::parse_color(colour)
                        .with_context(|| format!("in scene {name:?}"))?;
                }
                if let Some(held) = &surface.stop_after {
                    if crate::idle::parse_duration(held).is_none() {
                        bail!("scene {name:?} has stop_after {held:?}, not a duration like 30s");
                    }
                }
            }

            for key in &scene.keys {
                if key.reads() && key.action.count() > 0 {
                    bail!(
                        "scene {name:?} has a key that both reports and acts; a press can \
                         only do one of the two, so it changes what the key shows"
                    );
                }

                for ramp in [&key.ramp]
                    .into_iter()
                    .chain(key.cycle.iter().map(|view| &view.ramp))
                    .flatten()
                {
                    ramp.check().with_context(|| format!("in scene {name:?}"))?;
                }

                if let Some(icon) = &key.icon {
                    // An icon that is a template is only known once a feed has
                    // answered, so the name cannot be checked now.
                    if icon.contains('{') {
                        continue;
                    }
                    if crate::icons::get(icon).is_none() && !Path::new(icon).exists() {
                        bail!(
                            "scene {name:?} uses icon {icon:?}, which is neither bundled \
                             nor a file. Bundled icons: {}",
                            crate::icons::names().join(", ")
                        );
                    }
                }
            }

            let keys = scene.keys.iter().map(|k| &k.action);
            let encoders = scene
                .encoders
                .iter()
                .flat_map(|e| [&e.cw, &e.ccw, &e.press]);
            for action in keys.chain(scene.buttons.iter()).chain(encoders) {
                if action.count() > 1 {
                    bail!("scene {name:?} has a key with more than one action");
                }
                if let Some(shortcut) = &action.shortcut {
                    crate::action::check_shortcut(shortcut)
                        .with_context(|| format!("in scene {name:?}"))?;
                }
                if let Some(target) = &action.scene {
                    if !self.scenes.contains_key(target) {
                        bail!("scene {name:?} switches to {target:?}, which is not defined");
                    }
                }
            }
        }

        Ok(())
    }

    /// Scene claiming `bundle_id`, or the default scene.
    ///
    /// A pinned scene wins over everything: that is what pinning is.
    pub fn scene_for(&self, bundle_id: Option<&str>) -> &str {
        if let Some(pinned) = self.pinned.as_deref() {
            if self.scenes.contains_key(pinned) {
                return pinned;
            }
        }

        let Some(id) = bundle_id else {
            return &self.default;
        };

        for (name, scene) in &self.scenes {
            if scene.apps.iter().any(|pattern| matches_app(pattern, id)) {
                return name;
            }
        }

        &self.default
    }

    pub fn scene(&self, name: &str) -> Option<&Scene> {
        self.scenes.get(name)
    }

    /// Whether any binding sends a keystroke, which is the one thing that
    /// needs a permission.
    pub fn uses_shortcuts(&self) -> bool {
        self.scenes.values().any(|scene| {
            let keys = scene.keys.iter().map(|k| &k.action);
            let encoders = scene
                .encoders
                .iter()
                .flat_map(|e| [&e.cw, &e.ccw, &e.press]);

            keys.chain(scene.buttons.iter())
                .chain(encoders)
                .any(|a| a.shortcut.is_some())
        })
    }
}

/// Expands a leading `~` to the home directory.
///
/// People write paths with a tilde and nothing in Rust expands it, so a
/// perfectly good `~/Pictures/night.png` would be reported as missing.
pub fn expand(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    let Some(rest) = text.strip_prefix("~/") else {
        return path.to_path_buf();
    };
    match std::env::var_os("HOME") {
        Some(home) => PathBuf::from(home).join(rest),
        None => path.to_path_buf(),
    }
}

/// Matches a bundle ID against a pattern, where a trailing `*` is a prefix.
fn matches_app(pattern: &str, bundle_id: &str) -> bool {
    match pattern.strip_suffix('*') {
        Some(prefix) => bundle_id.to_lowercase().starts_with(&prefix.to_lowercase()),
        None => bundle_id.eq_ignore_ascii_case(pattern),
    }
}

/// Where the config lives: the argument, else `$XDG_CONFIG_HOME` or
/// `~/.config`. Created from [`EXAMPLE`] when it does not exist yet.
pub fn resolve_path(arg: Option<&str>) -> Result<PathBuf> {
    if let Some(arg) = arg {
        return Ok(PathBuf::from(arg));
    }

    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .context("neither XDG_CONFIG_HOME nor HOME is set")?;

    Ok(base.join("pult").join("config.toml"))
}

/// Header written above a generated config, since serialising drops comments.
const GENERATED_HEADER: &str = "\
# Pult configuration.
#
# Written by Pult. Hand-written comments are not preserved when the app saves
# this file; keep notes in a copy if you need them.
#
# See config.example.toml in the repository for what every field means.

";

impl Config {
    /// Writes the configuration back out as TOML.
    ///
    /// The previous file is kept alongside as `.bak`: this is the one place
    /// where the app can destroy work a person typed by hand.
    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;

        let body = toml::to_string_pretty(self).context("serialising config")?;
        let text = format!("{GENERATED_HEADER}{body}");

        if path.exists() {
            let backup = path.with_extension("toml.bak");
            fs::copy(path, &backup)
                .with_context(|| format!("backing up {} to {}", path.display(), backup.display()))?;
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }
}

pub fn create_if_missing(path: &Path) -> Result<bool> {
    if path.exists() {
        return Ok(false);
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, EXAMPLE).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_survives_a_round_trip() {
        // The app edits configs as JSON and the daemon writes them back as
        // TOML; anything lost in that loop is a setting silently thrown away.
        let original: Config = toml::from_str(EXAMPLE).expect("example parses");
        let toml_text = toml::to_string_pretty(&original).expect("serialises");
        let reparsed: Config = toml::from_str(&toml_text).expect("reparses");

        assert_eq!(original.scenes.len(), reparsed.scenes.len());
        for (name, scene) in &original.scenes {
            let other = reparsed.scenes.get(name).expect("scene survives");
            assert_eq!(scene.keys.len(), other.keys.len(), "keys of {name}");
            assert_eq!(scene.apps, other.apps, "apps of {name}");
            assert_eq!(scene.encoders.len(), other.encoders.len(), "encoders of {name}");
            for (a, b) in scene.keys.iter().zip(&other.keys) {
                assert_eq!(a.label, b.label);
                assert_eq!(a.icon, b.icon);
                assert_eq!(a.action.shortcut, b.action.shortcut);
                assert_eq!(a.animate, b.animate);
            }
        }
        reparsed.validate().expect("still valid");
    }

    #[test]
    fn app_patterns() {
        assert!(matches_app("com.apple.Safari", "com.apple.Safari"));
        assert!(matches_app("com.apple.safari", "com.apple.Safari"));
        assert!(matches_app("com.adobe.*", "com.adobe.Photoshop"));
        assert!(!matches_app("com.adobe.*", "com.apple.Safari"));
    }

    /// The weather page, cut down to the parts under test.
    const PAGE: &str = r##"
default = "vreme"

[feeds.vreme]
kind = "http"
url = "https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&current=temperature_2m"
every = "15m"
stale_after = "2h"
require = ["/current/temperature_2m"]

[feeds.vreme.map]
temp = "/current/temperature_2m"
hum = "/current/relative_humidity_2m"
rain6 = "max:/hourly/precipitation_probability[0:6]"
temp_h = { series = "/hourly/temperature_2m", axis = "/hourly/time", for = "temp" }

[[scenes.vreme.keys]]
value = "{vreme.temp|round}°"
caption = "oseća {vreme.feels|round}°"
icon = "thermometer"
ramp = { field = "vreme.temp", stops = [[-5, "#1f6feb"], [24, "#9a6700"]] }
cycle = [
  { value = "{vreme.hum|round}", caption = "% vlage" },
]

[[scenes.vreme.encoders]]
cw = { hour = "next" }
ccw = { hour = "prev" }
press = { hour = "now" }
"##;

    #[test]
    fn a_page_of_live_data_survives_a_round_trip() {
        let original: Config = toml::from_str(PAGE).expect("parses");
        original.validate().expect("validates");

        let text = toml::to_string_pretty(&original).expect("serialises");
        let again: Config = toml::from_str(&text).expect("reparses");
        again.validate().expect("still valid");

        let feed = &again.feeds["vreme"];
        assert_eq!(feed.require, vec!["/current/temperature_2m".to_string()]);
        assert_eq!(feed.map.len(), 4);

        let key = &again.scenes["vreme"].keys[0];
        assert_eq!(key.value.as_deref(), Some("{vreme.temp|round}°"));
        assert_eq!(key.cycle.len(), 1);
        assert_eq!(
            again.scenes["vreme"].encoders[0].cw.hour,
            Some(Hour::Next),
            "the knob still scrubs the forecast"
        );
        assert_eq!(key.feeds(), vec!["vreme".to_string()]);
    }

    #[test]
    fn a_cycle_member_carries_its_whole_reading() {
        let config: Config = toml::from_str(PAGE).expect("parses");
        let key = &config.scenes["vreme"].keys[0];

        assert_eq!(key.views(), 2);
        assert!(key.reads());

        let first = key.view(0);
        assert_eq!(first.value.as_deref(), Some("{vreme.temp|round}°"));
        assert!(first.ramp.is_some());

        let second = key.view(1);
        assert_eq!(second.value.as_deref(), Some("{vreme.hum|round}"));
        assert_eq!(second.caption.as_deref(), Some("% vlage"));
        // The reading travels whole: humidity must not inherit a ramp built
        // for a temperature, nor the caption that described one.
        assert!(second.ramp.is_none());
        // The key's own identity stays put.
        assert_eq!(second.icon.as_deref(), Some("thermometer"));

        // Pressing past the end comes back round.
        assert_eq!(key.view(2).value, first.value);
    }

    #[test]
    fn a_ramp_holds_at_both_ends_and_mixes_between() {
        let config: Config = toml::from_str(PAGE).expect("parses");
        let ramp = config.scenes["vreme"].keys[0].ramp.clone().expect("a ramp");

        assert_eq!(ramp.color(-40.0), ramp.color(-5.0), "it holds below the first");
        assert_eq!(ramp.color(50.0), ramp.color(24.0), "and above the last");

        let cold = ramp.color(-5.0).unwrap();
        let warm = ramp.color(24.0).unwrap();
        let middle = ramp.color(9.5).unwrap();
        for channel in 0..3 {
            let (low, high) = (cold[channel].min(warm[channel]), cold[channel].max(warm[channel]));
            assert!(
                (low..=high).contains(&middle[channel]),
                "the middle colour is between its stops"
            );
        }
        assert_ne!(middle, cold);
    }

    #[test]
    fn a_feed_or_a_key_that_cannot_work_is_refused_at_load() {
        let cases = [
            ("every = \"soon\"", "[feeds.x]\nkind=\"http\"\nurl=\"https://a.invalid\"\nevery=\"soon\""),
            ("a poll that fast", "[feeds.x]\nkind=\"http\"\nurl=\"https://a.invalid\"\nevery=\"0.5s\""),
            ("a url that is not one", "[feeds.x]\nkind=\"http\"\nurl=\"a.invalid\""),
            ("an http feed with no url", "[feeds.x]\nkind=\"http\""),
            (
                "a reducer nobody wrote",
                "[feeds.x]\nkind=\"http\"\nurl=\"https://a.invalid\"\n[feeds.x.map]\na=\"median:/x\"",
            ),
            (
                "require that is not a pointer",
                "[feeds.x]\nkind=\"http\"\nurl=\"https://a.invalid\"\nrequire=[\"current.temp\"]",
            ),
        ];
        for (what, feed) in cases {
            let text = format!("default = \"s\"\n{feed}\n[scenes.s]\n");
            let config: Config = toml::from_str(&text).unwrap_or_else(|e| panic!("{what}: {e}"));
            assert!(config.validate().is_err(), "{what} must be refused");
        }

        // A key cannot both report and act: the press can only do one.
        let both = r#"
default = "s"
[[scenes.s.keys]]
value = "{x.a}"
run = "open -a Safari"
"#;
        let config: Config = toml::from_str(both).expect("parses");
        assert!(config.validate().is_err());

        // A ramp whose stops run backwards mixes backwards.
        let backwards = r##"
default = "s"
[[scenes.s.keys]]
value = "{x.a}"
ramp = { field = "x.a", stops = [[20, "#ffffff"], [5, "#000000"]] }
"##;
        let config: Config = toml::from_str(backwards).expect("parses");
        assert!(config.validate().is_err());
    }

    #[test]
    fn a_key_reading_a_feed_nobody_configured_is_reported_not_refused() {
        let text = r#"
default = "s"
[[scenes.s.keys]]
value = "{vazduh.aqi|round}"
caption = "vazduh"
"#;
        let config: Config = toml::from_str(text).expect("parses");
        // It still runs: the app may be about to add the feed.
        config.validate().expect("validates");

        let reported = config.missing_files();
        assert_eq!(reported.len(), 1, "{reported:?}");
        assert!(reported[0].contains("vazduh"), "{}", reported[0]);
    }

    #[test]
    fn a_pinned_scene_wins_over_the_frontmost_application() {
        let text = r#"
default = "general"
pinned = "Vreme"
[scenes.general]
[scenes.Vreme]
[scenes.Chrome]
apps = ["com.google.Chrome"]
"#;
        let mut config: Config = toml::from_str(text).expect("parses");
        config.validate().expect("validates");

        assert_eq!(config.scene_for(Some("com.google.Chrome")), "Vreme");
        assert_eq!(config.scene_for(None), "Vreme");

        // Unpinned, it goes back to following what is in front.
        config.pinned = None;
        assert_eq!(config.scene_for(Some("com.google.Chrome")), "Chrome");
        assert_eq!(config.scene_for(None), "general");

        // A pin naming a scene that is not there is refused, the same way the
        // default scene is: a dock pinned to nothing has no answer at all.
        config.pinned = Some("Nema".into());
        assert!(config.validate().is_err());
    }

    #[test]
    fn a_rotate_cycles_the_pin_and_refuses_an_unknown_target() {
        let text = r#"
default = "general"
[scenes.general]
[scenes.Vreme]
[scenes."Mašina"]
[[scenes.general.buttons]]
rotate = ["", "Vreme", "Mašina"]
"#;
        let config: Config = toml::from_str(text).expect("parses");
        config.validate().expect("validates");

        // The button carries the list, and an empty entry is a valid step: it
        // is how the dock goes back to following the frontmost application.
        let targets = config.scenes["general"].buttons[0]
            .rotate
            .as_deref()
            .expect("a rotate");
        assert_eq!(targets, ["", "Vreme", "Mašina"]);

        // A step naming a scene the config does not define is refused, so the
        // button never lands on a dead stop.
        let bad = r#"
default = "general"
[scenes.general]
[[scenes.general.buttons]]
rotate = ["", "Nema"]
"#;
        let config: Config = toml::from_str(bad).expect("parses");
        assert!(config.validate().is_err());
    }

    #[test]
    fn example_config_is_valid() {
        let config: Config = toml::from_str(EXAMPLE).expect("example parses");
        config.validate().expect("example validates");
        assert_eq!(config.scene_for(Some("com.google.Chrome")), "chrome");
        assert_eq!(config.scene_for(Some("com.unknown.App")), config.default);
    }
}
