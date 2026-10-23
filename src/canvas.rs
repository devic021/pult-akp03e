//! The dock as one display.
//!
//! Six 60x60 screens with plastic between them are not a 180x120 image. The
//! gaps are real: about a quarter of a key wide, so a drawing that ignores them
//! shears at every seam. A canvas is therefore larger than the sum of its keys,
//! and each key is a window cut out of it at the right offset.
//!
//! Which is right depends on what is being drawn:
//!
//! * `Physical` keeps true geometry, a circle stays round, a diagonal stays
//!   straight, at the cost that a travelling front disappears for the width of
//!   each bezel. Right for rings, orbits and anything with a shape.
//! * `Packed` ignores the gaps, so a front crosses the dock at constant
//!   apparent speed and never stalls. Right for sweeps and meters.
//!
//! Static text and photographs belong on neither: a letter cut by 15 px of
//! plastic is a letter gone.
//!
//! Every effect below is a pure function of `(tau, style)`. `tau` is a phase
//! accumulator the daemon advances by `dt * speed`, which is why no formula
//! here ever reads a speed: turning the knob changes how fast tau grows, never
//! where the picture currently is, so the dock never jumps when you drag it.

use image::{Rgb, RgbImage};
use serde::{Deserialize, Serialize};
use std::f32::consts::TAU;

/// The seam between two keys, as a fraction of a key. Taken from the device's
/// own proportions; it is the one number the whole canvas depends on.
const SEAM: f32 = 0.26;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Mapping {
    /// True geometry, bezels included.
    #[default]
    Physical,
    /// Keys butted together, for motion that must not stall at a seam.
    Packed,
}

pub struct Canvas {
    image: RgbImage,
    /// Distance between the top-left corners of two neighbouring keys.
    pitch: u32,
    key: u32,
    cols: u32,
    rows: u32,
}

impl Canvas {
    pub fn new(mapping: Mapping, cols: u32, rows: u32, key: u32) -> Canvas {
        let pitch = match mapping {
            Mapping::Physical => (key as f32 * (1.0 + SEAM)).round() as u32,
            Mapping::Packed => key,
        };
        // The canvas spans the keys, not the plastic past the last one.
        let width = cols * pitch - (pitch - key);
        let height = rows * pitch - (pitch - key);

        Canvas {
            image: RgbImage::new(width, height),
            pitch,
            key,
            cols,
            rows,
        }
    }

    pub fn width(&self) -> u32 {
        self.image.width()
    }

    pub fn height(&self) -> u32 {
        self.image.height()
    }

    pub fn image_mut(&mut self) -> &mut RgbImage {
        &mut self.image
    }

    pub fn fill(&mut self, colour: Rgb<u8>) {
        for pixel in self.image.pixels_mut() {
            *pixel = colour;
        }
    }

    /// Where a key's window sits on the canvas.
    pub fn origin(&self, index: u32) -> (u32, u32) {
        let row = index / self.cols;
        let column = index % self.cols;
        (column * self.pitch, row * self.pitch)
    }

    pub fn keys(&self) -> u32 {
        self.cols * self.rows
    }

    /// One key's view of the canvas.
    pub fn tile(&self, index: u32) -> RgbImage {
        let (x, y) = self.origin(index);
        let mut tile = RgbImage::new(self.key, self.key);
        for ty in 0..self.key {
            for tx in 0..self.key {
                let sx = (x + tx).min(self.image.width() - 1);
                let sy = (y + ty).min(self.image.height() - 1);
                tile.put_pixel(tx, ty, *self.image.get_pixel(sx, sy));
            }
        }
        tile
    }

    /// Blends a colour into one pixel, ignoring anything off the canvas.
    pub fn blend(&mut self, x: i32, y: i32, colour: Rgb<u8>, alpha: f32) {
        if x < 0 || y < 0 || x >= self.image.width() as i32 || y >= self.image.height() as i32 {
            return;
        }
        let alpha = alpha.clamp(0.0, 1.0);
        let pixel = self.image.get_pixel_mut(x as u32, y as u32);
        for channel in 0..3 {
            let base = f32::from(pixel[channel]);
            pixel[channel] = (base + (f32::from(colour[channel]) - base) * alpha).round() as u8;
        }
    }
}

/// Which way the motion goes. The four axial directions are the ones the
/// travelling effects understand; `cw`/`ccw` spin and `out`/`in` radiate, and
/// an effect that has no use for a rotation falls back to its own axis rather
/// than refusing the setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dir {
    Right,
    Left,
    Up,
    Down,
    Cw,
    Ccw,
    Out,
    In,
}

/// What happens at the end of a loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Cycle {
    /// Start again from the far side.
    #[default]
    Wrap,
    /// Turn round and come back.
    Bounce,
}

/// The envelope `breathe` rides.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Shape {
    #[default]
    Sine,
    Ease,
    Heartbeat,
}

/// Everything an effect is allowed to know, resolved once per frame.
///
/// One field per TOML key, named identically, so a name means the same thing in
/// the config file, in this struct and on the row in the editor. Defaults are
/// applied before this is built, see `Surface::style`, so nothing in here is
/// ever an `Option` and no effect contains an `unwrap_or`.
#[derive(Debug, Clone, Copy)]
pub struct Style {
    // --- colour, already resolved (color_cycle applied, color2 derived)
    /// The hot colour.
    pub c: Rgb<u8>,
    /// The second stop.
    pub k: Rgb<u8>,
    pub background: Rgb<u8>,

    // --- shared
    /// 0..1 master fade; the idle ramp's hook.
    pub opacity: f32,
    /// 0..1 feather width as a fraction of a feature.
    pub softness: f32,
    /// 0.25..4 multiplies every length, divides every spatial frequency.
    pub scale: f32,
    /// 0.1..3 multiplies every count.
    pub density: f32,
    pub dir: Dir,
    pub cycle: Cycle,
    /// 0..1 fractions of the canvas; `pulse` and `warp` only.
    pub origin: (f32, f32),
    pub seed: u32,
    /// False lets a member be drawn over another, which the idle cross-fade
    /// needs: two effects painted into one canvas, not two canvases mixed.
    pub clear: bool,

    // --- per effect, defaults already applied
    /// `sweep`: tilts the bar into a diagonal wipe.
    pub shear: f32,
    /// `wave`: how much of the tank below the crest is filled.
    pub fill: f32,
    /// `aurora`: 0 a smooth field, 3-5 posterised steps.
    pub bands: u8,
    /// `rain`: sideways drift per step along the streak.
    pub wind: f32,
    /// `orbit`: how many times the path goes round in each axis.
    pub lobes: (u8, u8),
    /// `orbit`, `warp`: seconds of the past still drawn.
    pub trail: f32,
    /// `warp`: 1 a drift, 2.4 perspective, 4 a violent jump.
    pub exponent: f32,
    /// `lava`: low merges everything, high separates islands.
    pub threshold: f32,
    /// `ember`: how far up the span the flame reaches.
    pub height: f32,
    /// `ember`: dissolve the tip into the background.
    pub smoke: f32,
    /// `breathe`: which envelope.
    pub shape: Shape,
    /// `breathe`: the level at the bottom of a breath.
    pub floor: f32,
}

impl Style {
    /// Blends with `opacity` folded in. Every effect writes through this, so
    /// the master fade and the clamp exist in exactly one place.
    fn put(&self, canvas: &mut Canvas, x: f32, y: f32, colour: Rgb<u8>, alpha: f32) {
        let alpha = alpha * self.opacity;
        if alpha <= 0.002 {
            return;
        }
        canvas.blend(x.round() as i32, y.round() as i32, colour, alpha);
    }

    /// `lerp(c, k, u)`. Every member has exactly one axis worth colouring, and
    /// this is it: 0 is the cool end, 1 the hot core.
    fn tint(&self, u: f32) -> Rgb<u8> {
        mix(self.c, self.k, u.clamp(0.0, 1.0))
    }

    /// The one edge rule. `u` is how far inside the feature a pixel is: 1 at
    /// the core, 0 at the boundary. A `softness` of 0.02 is a hard cut, 1.0 a
    /// fade across the whole half-width. This replaces the dozen different
    /// falloff, edge, sharpness and tail-curve knobs the effects used to want.
    fn feather(&self, u: f32) -> f32 {
        if u <= 0.0 {
            return 0.0;
        }
        smoothstep(0.0, 1.0, (u / self.softness.max(0.02)).min(1.0))
    }
}

/// Phase. `wrap` runs 0..1 and starts over; `bounce` runs up and back down.
fn phi(tau: f32, period: f32, cycle: Cycle) -> f32 {
    let period = period.max(0.001);
    match cycle {
        Cycle::Wrap => (tau / period).rem_euclid(1.0),
        Cycle::Bounce => 1.0 - (2.0 * (tau / (2.0 * period)).rem_euclid(1.0) - 1.0).abs(),
    }
}

/// The only randomness in the catalogue: a pure function of `(i, salt, seed)`,
/// so the arrangement is reproducible and a repaint resumes where the eye left
/// off instead of reshuffling itself.
fn h(i: u32, salt: u32, seed: u32) -> f32 {
    let mut x = i
        .wrapping_mul(0x9E37_79B9)
        ^ salt.wrapping_mul(0x85EB_CA6B)
        ^ seed.wrapping_mul(0xC2B2_AE35);
    x ^= x >> 16;
    x = x.wrapping_mul(0x7FEB_352D);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846C_A68B);
    x ^= x >> 16;
    (x >> 8) as f32 / 16_777_216.0
}

/// Resolves `dir` once into `(p, q, span, cross)` so an axial effect never
/// reads x and y and never contains a `match` on the direction. `p` runs along
/// the travel, `q` across it.
fn axis(dir: Dir, x: f32, y: f32, width: f32, height: f32) -> (f32, f32, f32, f32) {
    match dir {
        Dir::Right | Dir::Out => (x, y, width, height),
        Dir::Left | Dir::In => (width - 1.0 - x, y, width, height),
        Dir::Down | Dir::Cw => (y, x, height, width),
        Dir::Up | Dir::Ccw => (height - 1.0 - y, x, height, width),
    }
}

/// The inverse, for effects that build a feature in `(p, q)` and then place it.
fn unaxis(dir: Dir, p: f32, q: f32, width: f32, height: f32) -> (f32, f32) {
    match dir {
        Dir::Right | Dir::Out => (p, q),
        Dir::Left | Dir::In => (width - 1.0 - p, q),
        Dir::Down | Dir::Cw => (q, p),
        Dir::Up | Dir::Ccw => (q, height - 1.0 - p),
    }
}

/// The span and cross extent for a direction, without a pixel.
fn extent(dir: Dir, width: f32, height: f32) -> (f32, f32) {
    let (_, _, span, cross) = axis(dir, 0.0, 0.0, width, height);
    (span, cross)
}

/// Burn-in and seam fairness, not a matter of taste, so not a knob: the whole
/// field drifts four pixels on two periods that share no common multiple. A
/// blob parked behind plastic is back on glass inside a minute.
fn wander(tau: f32) -> (f32, f32) {
    const AMPLITUDE: f32 = 4.0;
    (
        (tau * TAU / 61.0).sin() * AMPLITUDE,
        (tau * TAU / 47.0).cos() * AMPLITUDE,
    )
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

pub(crate) fn mix(a: Rgb<u8>, b: Rgb<u8>, u: f32) -> Rgb<u8> {
    let u = u.clamp(0.0, 1.0);
    Rgb([
        (f32::from(a[0]) + (f32::from(b[0]) - f32::from(a[0])) * u).round() as u8,
        (f32::from(a[1]) + (f32::from(b[1]) - f32::from(a[1])) * u).round() as u8,
        (f32::from(a[2]) + (f32::from(b[2]) - f32::from(a[2])) * u).round() as u8,
    ])
}

/// The output volume, across the whole dock.
///
/// The whole height, filled from the left, rather than a bar through the
/// middle. A band drawn across the centre lands exactly on the horizontal
/// seam and arrives as two separate strips, one at the foot of the top row
/// and one at the head of the bottom: the picture says "two" when it means
/// "one". Filling every key to its full height leaves nothing for a seam to
/// cut, and reads from across a room.
///
/// Muted is not drawn as an empty dock. An empty dock and a volume of zero
/// are the same picture and are not the same thing, so the level stays where
/// it is and dims: what you are turning back to is still visible.
pub fn meter(canvas: &mut Canvas, level: f32, muted: bool, tint: Rgb<u8>, background: Rgb<u8>) {
    canvas.fill(background);

    let filled = canvas.width() as f32 * level.clamp(0.0, 1.0);
    let (lit, rest) = if muted { (0.34, 0.10) } else { (0.92, 0.16) };

    for y in 0..canvas.height() as i32 {
        for x in 0..canvas.width() as i32 {
            // Fractional at the leading edge: snapped to whole pixels the
            // edge would stand still through most of a slow turn.
            let coverage = (filled - x as f32).clamp(0.0, 1.0);
            canvas.blend(x, y, tint, rest + (lit - rest) * coverage);
        }
    }
}

/// What the canvas does over time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    /// A bright band crossing the dock.
    Sweep,
    /// A travelling sine, drawn as a lit crest over an optional tank.
    Wave,
    /// Rings expanding from a point.
    Pulse,
    /// Falling streaks.
    Rain,
    /// Slow drifting colour, with nothing to track.
    Aurora,
    /// One bright head running a closed loop, dragging a tail.
    Orbit,
    /// Points streaking outward and lengthening as they go.
    Warp,
    /// Big soft blobs that drift, neck together and merge.
    Lava,
    /// Fire licking up from one edge, tearing into tongues.
    Ember,
    /// The whole dock swelling and fading as one lamp.
    Breathe,
}

impl Effect {
    /// The mapping this effect is drawn in unless the config says otherwise.
    pub fn mapping(self) -> Mapping {
        match self {
            // A front that stalls at every bezel reads as a stutter, so these
            // are drawn as though the keys were butted together.
            Effect::Sweep | Effect::Wave | Effect::Rain | Effect::Ember => Mapping::Packed,
            // These have a shape, and a shape must survive the gaps.
            Effect::Pulse
            | Effect::Aurora
            | Effect::Orbit
            | Effect::Warp
            | Effect::Lava
            | Effect::Breathe => Mapping::Physical,
        }
    }

    /// Frames per second this effect wants. Nothing here is compute-bound; the
    /// cost of a higher number is time on the wire, not a busy core.
    pub fn fps(self) -> u8 {
        match self {
            Effect::Aurora | Effect::Breathe => 8,
            Effect::Lava => 10,
            _ => 15,
        }
    }

    /// How long until the motion repeats, in tau-seconds.
    ///
    /// Used to decide how many frames a preview needs. Lava and ember never
    /// truly repeat, so they report a length that reads as a loop instead of
    /// pretending to be one.
    pub fn period(self) -> f32 {
        match self {
            Effect::Sweep => 2.6,
            Effect::Wave => 1.0 / 1.7,
            Effect::Pulse => 2.2,
            Effect::Rain => 4.0,
            Effect::Aurora => 8.0,
            Effect::Orbit => 2.4,
            Effect::Warp => 3.2,
            Effect::Lava => 24.0,
            Effect::Ember => 6.0,
            Effect::Breathe => 5.0,
        }
    }

    /// Every effect, in the order a gallery should show them.
    pub fn all() -> [Effect; 10] {
        [
            Effect::Sweep,
            Effect::Wave,
            Effect::Pulse,
            Effect::Rain,
            Effect::Aurora,
            Effect::Orbit,
            Effect::Warp,
            Effect::Lava,
            Effect::Ember,
            Effect::Breathe,
        ]
    }

    /// The axis this effect was designed around, used when `direction` is
    /// unset. Saying "the effect's own" out loud in one place beats five
    /// scattered `unwrap_or`s that drift apart.
    pub fn dir(self) -> Dir {
        match self {
            Effect::Sweep | Effect::Wave | Effect::Aurora | Effect::Lava | Effect::Breathe => {
                Dir::Right
            }
            Effect::Rain => Dir::Down,
            Effect::Ember => Dir::Up,
            Effect::Orbit => Dir::Cw,
            Effect::Pulse | Effect::Warp => Dir::Out,
        }
    }

    /// The config spelling.
    pub fn name(self) -> &'static str {
        match self {
            Effect::Sweep => "sweep",
            Effect::Wave => "wave",
            Effect::Pulse => "pulse",
            Effect::Rain => "rain",
            Effect::Aurora => "aurora",
            Effect::Orbit => "orbit",
            Effect::Warp => "warp",
            Effect::Lava => "lava",
            Effect::Ember => "ember",
            Effect::Breathe => "breathe",
        }
    }

    /// The name on the gallery tile.
    pub fn title(self) -> &'static str {
        match self {
            Effect::Sweep => "Sweep",
            Effect::Wave => "Wave",
            Effect::Pulse => "Pulse",
            Effect::Rain => "Rain",
            Effect::Aurora => "Aurora",
            Effect::Orbit => "Orbit",
            Effect::Warp => "Warp",
            Effect::Lava => "Lava",
            Effect::Ember => "Ember",
            Effect::Breathe => "Breathe",
        }
    }

    /// One line under the tile, describing what you will see rather than how it
    /// is computed.
    pub fn sentence(self) -> &'static str {
        match self {
            Effect::Sweep => "A bar of light wipes across the dock and comes round again.",
            Effect::Wave => "A travelling swell, as a bright crest or as liquid in a tank.",
            Effect::Pulse => "Rings leave a point and fade as they widen.",
            Effect::Rain => "Streaks fall at their own speeds, leaning with the wind.",
            Effect::Aurora => "A slow field of colour with nothing in it to follow.",
            Effect::Orbit => "A bright head runs a closed loop and drags its own blur.",
            Effect::Warp => "Points streak out from the middle, lengthening as they fly.",
            Effect::Lava => "Soft blobs drift, neck together and merge.",
            Effect::Ember => "Fire climbs from one edge and tears into tongues.",
            Effect::Breathe => "The whole dock swells and fades as a single lamp.",
        }
    }

    /// Every knob this effect honours, in the order the editor shows them.
    ///
    /// The only source of truth: the `effects` socket reply carries this, the
    /// app renders one row per entry, and a new effect grows the gallery with
    /// no app build. A knob the effect ignores is left out rather than shown
    /// dead, a slider that does nothing is worse than a slider that is absent.
    pub fn knobs(self) -> &'static [&'static str] {
        match self {
            Effect::Sweep => &[
                "speed", "direction", "cycle", "scale", "density", "softness", "shear", "color",
                "color2", "color_cycle", "background", "opacity", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Wave => &[
                "speed", "direction", "scale", "density", "softness", "fill", "color", "color2",
                "color_cycle", "background", "opacity", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Pulse => &[
                "speed", "direction", "cycle", "scale", "density", "softness", "origin", "color",
                "color2", "color_cycle", "background", "opacity", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Rain => &[
                "speed", "direction", "cycle", "scale", "density", "softness", "wind", "color",
                "color2", "color_cycle", "background", "opacity", "seed", "mapping", "fps",
                "stop_after", "reduce_motion",
            ],
            Effect::Aurora => &[
                "speed", "direction", "scale", "softness", "bands", "color", "color2",
                "color_cycle", "background", "opacity", "seed", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Orbit => &[
                "speed", "direction", "cycle", "scale", "density", "softness", "lobes", "trail",
                "color", "color2", "color_cycle", "background", "opacity", "mapping", "fps",
                "stop_after", "reduce_motion",
            ],
            Effect::Warp => &[
                "speed", "direction", "scale", "density", "softness", "exponent", "trail",
                "origin", "color", "color2", "color_cycle", "background", "opacity", "seed",
                "mapping", "fps", "stop_after", "reduce_motion",
            ],
            Effect::Lava => &[
                "speed", "scale", "density", "softness", "threshold", "color", "color2",
                "color_cycle", "background", "opacity", "seed", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Ember => &[
                "speed", "direction", "scale", "softness", "height", "smoke", "color", "color2",
                "color_cycle", "background", "opacity", "seed", "mapping", "fps", "stop_after",
                "reduce_motion",
            ],
            Effect::Breathe => &[
                "speed", "cycle", "shape", "floor", "color", "color2", "color_cycle",
                "background", "opacity", "mapping", "fps", "stop_after", "reduce_motion",
            ],
        }
    }
}

/// Draws one frame.
///
/// `tau` is the phase accumulator, in tau-seconds. The background is laid down
/// only when `style.clear` is set, so two effects can be painted into one
/// canvas for a cross-fade.
pub fn draw(effect: Effect, canvas: &mut Canvas, tau: f32, style: &Style) {
    if style.clear {
        canvas.fill(style.background);
    }

    match effect {
        Effect::Sweep => sweep(canvas, tau, style),
        Effect::Wave => wave(canvas, tau, style),
        Effect::Pulse => pulse(canvas, tau, style),
        Effect::Rain => rain(canvas, tau, style),
        Effect::Aurora => aurora(canvas, tau, style),
        Effect::Orbit => orbit(canvas, tau, style),
        Effect::Warp => warp(canvas, tau, style),
        Effect::Lava => lava(canvas, tau, style),
        Effect::Ember => ember(canvas, tau, style),
        Effect::Breathe => breathe(canvas, tau, style),
    }
}

/// A bar of light, with a soft tail behind it and a faint glow running ahead.
/// The glow is what stops a hard edge from looking like a dropped frame when it
/// emerges from under a bezel.
fn sweep(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (span, cross) = extent(style.dir, width, height);

    let bars = style.density.round().clamp(1.0, 4.0) as u32;
    let tail = 46.0 * style.scale;
    let lead = 10.0 * style.scale;
    // One bar crosses in span/70 tau-seconds, so the picture travels at a
    // constant 70 px per tau-second whatever the dock's size.
    let base = phi(tau, span / 70.0, style.cycle);

    let heads: Vec<f32> = (0..bars)
        .map(|bar| {
            let psi = (base + bar as f32 / bars as f32).fract();
            psi * (span + 2.0 * tail) - tail
        })
        .collect();

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let (p, q, _, _) = axis(style.dir, x as f32, y as f32, width, height);
            let skew = style.shear * (q - cross / 2.0);

            for head in &heads {
                let d = head - p + skew;
                if d >= 0.0 && d <= tail {
                    let u = 1.0 - d / tail;
                    style.put(canvas, x as f32, y as f32, style.tint(u * u), style.feather(u));
                } else if d < 0.0 && d >= -lead {
                    let u = 1.0 + d / lead;
                    style.put(canvas, x as f32, y as f32, style.tint(0.0), 0.45 * u * u);
                }
            }
        }
    }
}

/// A swell. Two sines of different wavelength, so the crest is not a textbook
/// curve; `fill` decides whether you are looking at a line or at a tank with
/// something in it.
fn wave(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (span, cross) = extent(style.dir, width, height);

    let lam = (span / (1.6 * style.density.max(0.1))).max(4.0);
    let thickness = 12.0 * style.scale;

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let (p, q, _, _) = axis(style.dir, x as f32, y as f32, width, height);
            let theta = TAU * (p / lam - 1.7 * tau);
            let crest =
                cross * 0.5 + cross * 0.28 * (theta.sin() + 0.35 * (2.0 * theta + 1.7).sin()) / 1.35;
            let d = q - crest;

            let line = style.feather((1.0 - d.abs() / thickness).max(0.0));
            if line > 0.0 {
                style.put(canvas, x as f32, y as f32, style.tint(1.0), line);
            }

            if style.fill > 0.0 && d > 0.0 {
                let depth = (d / thickness).min(1.0);
                let floor = (d / (cross - crest).max(1.0)).min(1.0);
                let body = style.fill * depth * (1.0 - floor).powf(0.6);
                if body > 0.0 {
                    style.put(canvas, x as f32, y as f32, style.tint(0.25), body);
                }
            }
        }
    }
}

/// Rings leaving a point. Drawn in physical geometry so they stay round across
/// the bezels, and born at the dead centre of the horizontal seam by default,
/// which means a ring is already sixteen pixels across when it first appears,
/// exactly how you want something to arrive.
fn pulse(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (drift_x, drift_y) = wander(tau);
    let cx = width * style.origin.0 + drift_x;
    let cy = height * style.origin.1 + drift_y;

    // The far corner, so the last ring leaves the canvas rather than stopping.
    let largest = [(0.0, 0.0), (width, 0.0), (0.0, height), (width, height)]
        .iter()
        .map(|(x, y)| ((x - cx).powi(2) + (y - cy).powi(2)).sqrt())
        .fold(1.0, f32::max);

    let rings = (3.0 * style.density).round().clamp(1.0, 6.0) as u32;
    let thickness = 7.0 * style.scale;
    let base = phi(tau, 2.2, style.cycle);
    let inward = style.dir == Dir::In || style.dir == Dir::Left || style.dir == Dir::Up;

    // Resolved once: the per-pixel loop below must not pay for a ring twice.
    let fronts: Vec<(f32, f32)> = (0..rings)
        .map(|ring| {
            let mut psi = (base + ring as f32 / rings as f32).fract();
            if inward {
                psi = 1.0 - psi;
            }
            (psi * largest, 1.0 - psi)
        })
        .collect();

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let distance = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
            for (radius, fade) in &fronts {
                let u = 1.0 - (distance - radius).abs() / thickness;
                let alpha = style.feather(u) * fade * 0.9;
                if alpha > 0.0 {
                    style.put(canvas, x as f32, y as f32, style.tint(u.max(0.0)), alpha);
                }
            }
        }
    }
}

/// Streaks, each with its own speed. They are spread evenly across the dock and
/// jittered rather than placed at random, because fourteen random columns
/// leave a key dark about one time in a hundred, and a dark key reads as a
/// broken key.
fn rain(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (span, cross) = extent(style.dir, width, height);

    let streaks = (14.0 * style.density).round().clamp(1.0, 80.0) as u32;
    // Below sixteen pixels a streak stops bridging a seam and the rain reads as
    // a row of blinking dots.
    let length = (18.0 * style.scale).max(16.0);
    let thickness = (2.0 * style.scale).round().max(1.0) as i32;
    let (drift, _) = wander(tau);

    for i in 0..streaks {
        let velocity = 50.0 * (0.7 + 0.6 * h(i, 1, style.seed));
        let travel = span + length;
        let head = ((tau * velocity + h(i, 0, style.seed) * travel) / travel).fract() * travel
            - length;
        let lane = (i as f32 + 0.35 + 0.3 * h(i, 2, style.seed)) / streaks as f32 * cross + drift;

        for step in 0..length as u32 {
            let s = step as f32;
            let u = 1.0 - s / length;
            // The head is brighter than the formula allows, deliberately: it is
            // what the eye tracks across a seam.
            let alpha = style.feather(u) * if step == 0 { 1.3 } else { 1.0 };
            if alpha <= 0.0 {
                continue;
            }
            let (x, y) = unaxis(style.dir, head - s, lane + style.wind * s, width, height);
            let colour = style.tint(u);
            for t in 0..thickness {
                let (ox, oy) = match style.dir {
                    Dir::Down | Dir::Cw | Dir::Up | Dir::Ccw => (t as f32, 0.0),
                    _ => (0.0, t as f32),
                };
                style.put(canvas, x + ox, y + oy, colour, alpha * if t == 0 { 1.0 } else { 0.45 });
            }
        }
    }
}

/// Three slow fields crossing on periods that share no common multiple, so
/// nothing repeats on a beat you can hear. `bands` posterises it into curtains.
fn aurora(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (span, _) = extent(style.dir, width, height);
    let nu = 1.0 / style.scale.max(0.05);
    let (drift_x, drift_y) = wander(tau);
    let sharpness = 0.5 + 2.0 * (1.0 - style.softness.clamp(0.0, 1.0));
    // Where each of the three fields starts. The character is in the periods,
    // which never change; the seed only decides where in them this dock sits.
    let (o1, o2, o3) = (
        TAU * h(0, 11, style.seed),
        TAU * h(0, 12, style.seed),
        TAU * h(0, 13, style.seed),
    );

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let fx = (x as f32 + drift_x) / width;
            let fy = (y as f32 + drift_y) / height;
            // Between two and three cycles across the dock. Less than one,
            // which is what 2.4 radians over a 0..1 fraction gives, is not a
            // field, it is a gradient, and on the contact sheet it read as one
            // flat wash that barely moved.
            let field = (fx * 6.0 * nu + tau * 0.23 + o1).sin()
                + (fy * 4.6 * nu - tau * 0.17 + o2).cos()
                + 0.5 * ((fx + fy) * 3.4 * nu + tau * 0.11 + o3).sin();

            // Divided by 2.0, not 2.5: the three sines almost never all peak at
            // once, so normalising by the arithmetic maximum left the field
            // sitting in the middle of its range with no contrast anywhere.
            let mut n = (field / 2.0 * 0.5 + 0.5).clamp(0.0, 1.0);
            if style.bands > 0 {
                let bands = f32::from(style.bands);
                let stepped = n * bands;
                n = (stepped.floor() + smoothstep(0.35, 0.65, stepped.fract())) / bands;
            }
            n = n.powf(sharpness);

            // The light leans the way the field travels, so a direction still
            // means something to an effect with no front to move.
            let (p, _, _, _) = axis(style.dir, x as f32, y as f32, width, height);
            let tilt = 0.55 + 0.45 * (p / span);
            // 0.85, not 0.55. An aurora is meant to be quiet, not absent, and
            // at a third of an alpha with nothing to track it read as a dock
            // that had failed to paint.
            style.put(canvas, x as f32, y as f32, style.tint(n), n * 0.85 * tilt);
        }
    }
}

/// A head on a closed path, drawn as twenty-four discs back along where it has
/// just been. That is true motion blur, and it is the only mechanism in the
/// catalogue that lets a five-pixel head survive a sixteen-pixel seam: the tail
/// is still on the far key when the head arrives on the near one, and the eye
/// joins them up by itself.
fn orbit(canvas: &mut Canvas, tau: f32, style: &Style) {
    const SAMPLES: u32 = 24;
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (drift_x, drift_y) = wander(tau);

    let bodies = style.density.round().clamp(1.0, 4.0) as u32;
    // Ten, not five. Five is a scratch at arm's length; ten reads as an object
    // while still being smaller than the sixteen-pixel seam, so the trail is
    // still what carries it across the plastic rather than its own width.
    let radius = 10.0 * style.scale;
    let spin = if style.dir == Dir::Ccw || style.dir == Dir::Left {
        -1.0
    } else {
        1.0
    };
    let lobe_p = f32::from(style.lobes.0.max(1));
    let lobe_q = f32::from(style.lobes.1.max(1));
    let base = phi(tau, 2.4, style.cycle);
    // The trail is a stretch of the path, not of the clock, so it keeps its
    // length when the speed knob moves.
    let back = (style.trail / 2.4).clamp(0.0, 0.9);

    for body in 0..bodies {
        let start = base + body as f32 / bodies as f32;
        for k in 0..SAMPLES {
            let age = k as f32 / SAMPLES as f32;
            let s = start - back * age;
            let px = width / 2.0 + 0.36 * width * (TAU * s * lobe_p * spin).cos() + drift_x;
            let py = height / 2.0 + 0.34 * height * (TAU * s * lobe_q).sin() + drift_y;

            let r = (radius * (1.0 - 0.6 * age)).max(0.8);
            let weight = style.feather(1.0 - age);
            if weight <= 0.0 {
                continue;
            }
            let colour = style.tint(1.0 - age);

            let span = r.ceil() as i32;
            for dy in -span..=span {
                for dx in -span..=span {
                    let d = ((dx * dx + dy * dy) as f32).sqrt();
                    let core = style.feather(1.0 - d / r);
                    if core > 0.0 {
                        style.put(canvas, px + dx as f32, py + dy as f32, colour, weight * core);
                    }
                }
            }
        }
    }
}

/// Stars born near the middle and thrown outward, each drawn as ten samples
/// back along its own path. Because the path is closed-form in the star's
/// progress, the streak lengthens by itself as the star accelerates, the jump
/// to light speed, without a single extra parameter.
fn warp(canvas: &mut Canvas, tau: f32, style: &Style) {
    const SAMPLES: u32 = 10;
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (drift_x, drift_y) = wander(tau);
    let cx = width * style.origin.0 + drift_x;
    let cy = height * style.origin.1 + drift_y;

    let stars = (48.0 * style.density).round().clamp(8.0, 300.0) as u32;
    let birth = 18.0 * style.scale;
    let largest = [(0.0, 0.0), (width, 0.0), (0.0, height), (width, height)]
        .iter()
        .map(|(x, y)| ((x - cx).powi(2) + (y - cy).powi(2)).sqrt())
        .fold(1.0, f32::max);
    let exponent = style.exponent.clamp(0.2, 8.0);
    let swirl = match style.dir {
        Dir::Cw => 0.3,
        Dir::Ccw => -0.3,
        _ => 0.0,
    };
    let inward = style.dir == Dir::In;
    let back = (style.trail / 3.2).clamp(0.0, 0.9);

    for i in 0..stars {
        let angle = TAU * h(i, 0, style.seed) + swirl * tau;
        let pace = 0.7 + 0.6 * h(i, 1, style.seed);
        let z0 = (h(i, 2, style.seed) + tau * pace / 3.2).fract();

        for j in 0..SAMPLES {
            let age = j as f32 / SAMPLES as f32;
            let z = z0 - back * age;
            if z <= 0.0 {
                break;
            }
            let t = if inward { 1.0 - z } else { z };
            let r = birth + (largest - birth) * t.powf(exponent);
            // A star that pops into existence at full brightness looks like a
            // dead pixel, so the first fifteenth of its life is a fade-in.
            let alpha = style.feather(1.0 - age) * smoothstep(0.0, 0.15, z);
            if alpha <= 0.0 {
                continue;
            }
            let x = cx + r * angle.cos();
            let y = cy + r * angle.sin();
            let colour = style.tint(1.0 - age);
            style.put(canvas, x, y, colour, alpha);
            style.put(canvas, x + 1.0, y, colour, alpha * 0.55);
            // A one-pixel star is invisible on glass with a bezel through the
            // middle, and the fast ones are exactly the ones worth seeing, so
            // a star thickens as it goes out.
            if t > 0.45 {
                style.put(canvas, x, y + 1.0, colour, alpha * 0.55);
                style.put(canvas, x + 1.0, y + 1.0, colour, alpha * 0.3);
            }
        }
    }
}

/// A summed inverse-square field over drifting centres. The sum is the whole
/// point: where two blobs come close the field between them crosses the
/// threshold and a neck grows, which is what separates this from a bag of
/// circles sliding past each other.
fn lava(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (drift_x, drift_y) = wander(tau);

    let blobs = (5.0 * style.density).round().clamp(2.0, 12.0) as u32;
    let radius = 32.0 * style.scale;
    let threshold = style.threshold.max(0.02);

    // Phases are spread, not drawn from the hash, so the blobs never start the
    // frame piled on one key.
    let centres: Vec<(f32, f32, f32)> = (0..blobs)
        .map(|i| {
            let spread = (i as f32 + h(i, 1, style.seed)) / blobs as f32;
            let x = 0.5 + 0.34 * (tau * 0.11 * (1.0 + 0.37 * h(i, 0, style.seed)) + TAU * spread).sin();
            let y = 0.5
                + 0.30 * (tau * 0.13 * (1.0 + 0.41 * h(i, 2, style.seed)) + TAU * spread * 1.7).cos();
            (
                x * width + drift_x,
                y * height + drift_y,
                radius * (0.6 + 0.8 * h(i, 3, style.seed)),
            )
        })
        .collect();

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let mut field = 0.0;
            for (bx, by, br) in &centres {
                let dx = x as f32 - bx;
                let dy = y as f32 - by;
                field += br * br / (dx * dx + dy * dy + 1.0);
            }
            if field <= threshold {
                continue;
            }
            let alpha = style.feather((field - threshold) / 0.6);
            if alpha > 0.0 {
                let heat = ((field - threshold) / (2.0 * threshold)).min(1.0);
                style.put(canvas, x as f32, y as f32, style.tint(heat), alpha);
            }
        }
    }
}

/// Fire. Three turbulent sines, and time enters only inside `(p + tau * v)`,
/// which is pure advection: the texture rises through the flame instead of
/// shimmering in place. Shimmer is what makes cheap fire look cheap.
fn ember(canvas: &mut Canvas, tau: f32, style: &Style) {
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let (span, _) = extent(style.dir, width, height);
    let nu = style.scale.max(0.05);
    let reach = style.height.clamp(0.05, 1.0);
    let (_, drift) = wander(tau);

    let phase1 = TAU * h(0, 1, style.seed);
    let phase2 = TAU * h(0, 2, style.seed);

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let (p, q, _, _) = axis(style.dir, x as f32, y as f32, width, height);
            let q = q + drift;
            let f = p / span;

            let turbulence = 0.5
                + 0.35 * (q * 0.09 / nu + (p + tau * 70.0) * 0.07 / nu + phase1).sin()
                + 0.15 * (q * 0.21 / nu - (p + tau * 119.0) * 0.17 / nu + phase2).sin()
                + 0.12 * (q * 0.045 / nu + tau * 0.9).sin();

            // `feather` is an edge rule: anything past `softness` of the way
            // in is fully inside. A flame has no edge along its height, it
            // has a falloff, so feeding the height into it painted the bottom
            // half of the dock as one solid block. The falloff is the value
            // itself, and `softness` shapes how fast it goes.
            let fade = (1.0 - f / reach).max(0.0);
            let alpha = (fade.powf(1.0 + 2.0 * style.softness) * turbulence * 1.8).clamp(0.0, 1.0);
            if alpha <= 0.002 {
                continue;
            }
            // Hot at the base, cooling as it climbs, and dissolving into the
            // background above `height` when there is smoke.
            let heat = (f / reach).min(1.0);
            let mut colour = mix(style.k, style.c, heat);
            if style.smoke > 0.0 {
                colour = mix(colour, style.background, style.smoke * heat);
            }
            style.put(canvas, x as f32, y as f32, colour, alpha);
        }
    }
}

/// One lamp. A canvas fill and a single cheap pass, and the only member of the
/// catalogue that is legible from across a room.
fn breathe(canvas: &mut Canvas, tau: f32, style: &Style) {
    const VIGNETTE: f32 = 0.25;
    let width = canvas.width() as f32;
    let height = canvas.height() as f32;
    let psi = phi(tau, 5.0, style.cycle);

    let envelope = match style.shape {
        Shape::Sine => 0.5 - 0.5 * (TAU * psi).cos(),
        Shape::Ease => smoothstep(0.0, 1.0, 1.0 - (2.0 * psi - 1.0).abs()),
        Shape::Heartbeat => {
            let beat = |centre: f32| (-((psi - centre) / 0.055).powi(2)).exp();
            // The wrapped copy keeps the first beat continuous across the loop.
            (beat(0.0) + beat(1.0) + 0.62 * beat(0.17)).min(1.0)
        }
    };

    let floor = style.floor.clamp(0.0, 1.0);
    let u = floor + (1.0 - floor) * envelope;
    let colour = style.tint(u);
    let cx = width / 2.0;
    let cy = height / 2.0;
    let far = (cx * cx + cy * cy).max(1.0);

    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let dx = x as f32 - cx;
            let dy = y as f32 - cy;
            let edge = 1.0 - VIGNETTE * ((dx * dx + dy * dy) / far);
            style.put(canvas, x as f32, y as f32, colour, u * edge);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The style the tests judge an effect by: every default the config layer
    /// would apply, so a failure here is the effect's fault and not a knob's.
    fn probe() -> Style {
        Style {
            c: Rgb([80, 160, 255]),
            k: Rgb([255, 255, 255]),
            background: Rgb([0, 0, 0]),
            opacity: 1.0,
            softness: 0.55,
            scale: 1.0,
            density: 1.0,
            dir: Dir::Right,
            cycle: Cycle::Wrap,
            origin: (0.5, 0.5),
            seed: 0,
            clear: true,
            shear: 0.0,
            fill: 0.0,
            bands: 0,
            wind: 0.0,
            lobes: (1, 1),
            trail: 0.30,
            exponent: 2.4,
            threshold: 1.0,
            height: 0.75,
            smoke: 0.0,
            shape: Shape::Sine,
            floor: 0.06,
        }
    }

    /// Each effect gets the direction it was designed around, the way the
    /// config layer hands it over.
    fn probe_for(effect: Effect) -> Style {
        let mut style = probe();
        style.dir = match effect {
            Effect::Rain => Dir::Down,
            Effect::Ember => Dir::Up,
            Effect::Orbit => Dir::Cw,
            Effect::Pulse | Effect::Warp => Dir::Out,
            _ => Dir::Right,
        };
        style
    }

    #[test]
    fn physical_canvas_leaves_room_for_the_seams() {
        let canvas = Canvas::new(Mapping::Physical, 3, 2, 60);
        // pitch 76, so three keys span 76 + 76 + 60.
        assert_eq!(canvas.width(), 212);
        assert_eq!(canvas.height(), 136);
        assert_eq!(canvas.origin(0), (0, 0));
        assert_eq!(canvas.origin(2), (152, 0));
        assert_eq!(canvas.origin(3), (0, 76));
    }

    #[test]
    fn packed_canvas_is_exactly_the_keys() {
        let canvas = Canvas::new(Mapping::Packed, 3, 2, 60);
        assert_eq!(canvas.width(), 180);
        assert_eq!(canvas.height(), 120);
        assert_eq!(canvas.origin(4), (60, 60));
    }

    #[test]
    fn a_tile_is_a_window_on_the_canvas() {
        let mut canvas = Canvas::new(Mapping::Packed, 3, 2, 60);
        canvas.fill(Rgb([0, 0, 0]));
        // Light one pixel inside the last key and look for it there.
        let (x, y) = canvas.origin(5);
        canvas.blend(x as i32 + 3, y as i32 + 4, Rgb([255, 255, 255]), 1.0);

        let tile = canvas.tile(5);
        assert_eq!(tile.get_pixel(3, 4)[0], 255);
        assert_eq!(canvas.tile(0).get_pixel(3, 4)[0], 0);
    }

    #[test]
    fn every_effect_puts_light_on_the_canvas() {
        for effect in Effect::all() {
            let style = probe_for(effect);
            let mut canvas = Canvas::new(effect.mapping(), 3, 2, 60);
            // Sampled over a second: a sweep is dark at some instants by design.
            let lit = (0..16)
                .map(|step| {
                    draw(effect, &mut canvas, step as f32 / 16.0, &style);
                    canvas.image_mut().pixels().filter(|p| p[2] > 10).count()
                })
                .max()
                .unwrap_or(0);
            assert!(lit > 100, "{effect:?} drew almost nothing");
        }
    }

    /// Seam fairness. A motion that only ever lights four of the six keys turns
    /// two keys into dead plastic, and on a desk that reads as a fault in the
    /// dock rather than a choice in the effect.
    #[test]
    fn a_seam_never_hides_a_whole_feature() {
        const STEPS: u32 = 48;
        for effect in Effect::all() {
            let style = probe_for(effect);
            let mut canvas = Canvas::new(effect.mapping(), 3, 2, 60);
            let mut brightest = [0u32; 6];

            for step in 0..STEPS {
                let tau = step as f32 * effect.period().min(4.0) / STEPS as f32;
                draw(effect, &mut canvas, tau, &style);
                for key in 0..canvas.keys() {
                    let lit = canvas
                        .tile(key)
                        .pixels()
                        .filter(|p| p[0] > 8 || p[1] > 8 || p[2] > 8)
                        .count() as u32;
                    brightest[key as usize] = brightest[key as usize].max(lit);
                }
            }

            for (key, lit) in brightest.iter().enumerate() {
                assert!(
                    *lit > 0,
                    "{effect:?} never lights key {key}; brightest was {brightest:?}"
                );
            }
        }
    }

    /// The catalogue says which knobs an effect honours; the table says what
    /// each one looks like. If a name is in one and not the other the editor
    /// gets a row it cannot draw, or a slider for something nothing reads.
    #[test]
    fn every_knob_an_effect_offers_has_a_row() {
        for effect in Effect::all() {
            for name in effect.knobs() {
                assert!(
                    knob(name).is_some(),
                    "{effect:?} offers {name:?}, which is in no table"
                );
            }
        }

        // And nothing sits in the table that no effect will ever ask for.
        let offered: std::collections::HashSet<&str> =
            Effect::all().iter().flat_map(|e| e.knobs()).copied().collect();
        for row in KNOBS {
            assert!(
                offered.contains(row.name),
                "the table has a row for {:?}, which no effect honours",
                row.name
            );
        }
    }

    /// A slider that runs further than the daemon accepts stops doing anything
    /// near its end, and looks broken while it does. The ranges the editor is
    /// told must be the ranges the daemon enforces, which holds only while
    /// `Surface::style` reads them from here.
    #[test]
    fn a_knob_clamps_to_what_it_advertises() {
        for row in KNOBS {
            if row.control != Control::Range {
                continue;
            }
            assert!(row.min < row.max, "{} has an empty range", row.name);
            assert!(
                row.number(Some(row.max + 1000.0)) <= row.max,
                "{} lets a value past its own maximum",
                row.name
            );
            assert!(
                row.number(Some(row.min - 1000.0)) >= row.min,
                "{} lets a value below its own minimum",
                row.name
            );
            if let Preset::Number(preset) = row.preset {
                assert!(
                    (row.min..=row.max).contains(&preset),
                    "{} defaults to {preset}, outside its own range",
                    row.name
                );
            }
        }
    }

    /// The shape the editor decodes, written down so a change to it has to
    /// change this line too. The app builds one control per entry and holds no
    /// table of its own, so this JSON is the whole contract between them.
    #[test]
    fn a_knob_crosses_the_socket_as_the_editor_expects() {
        let row = serde_json::to_value(k("scale")).unwrap();
        assert_eq!(row["name"], "scale");
        assert_eq!(row["control"], "range");
        assert_eq!(row["min"], 0.25);
        assert_eq!(row["max"], 4.0);
        assert_eq!(row["preset"], 1.0);
        assert!(row["says"].as_str().is_some_and(|line| !line.is_empty()));
        // A range has no options, and the field is left out rather than sent
        // empty, so the editor can tell "no choices" from "choices not loaded".
        assert!(row.get("options").is_none());

        let choice = serde_json::to_value(k("shape")).unwrap();
        assert_eq!(choice["control"], "choice");
        assert_eq!(choice["options"], serde_json::json!(["sine", "ease", "heartbeat"]));
        assert_eq!(choice["preset"], "sine");

        // Three knobs have no default of their own: the effect is the default,
        // and the catalogue entry already carries each effect's answer.
        assert_eq!(serde_json::to_value(k("direction")).unwrap()["preset"], "effect");

        let pair = serde_json::to_value(k("lobes")).unwrap();
        assert_eq!(pair["control"], "pair");
        assert_eq!(pair["preset"], serde_json::json!([1.0, 1.0]));
    }

    /// A repaint after a config reload, a resumed frame, a second preview: all
    /// of them must land on the picture the eye already had. That holds only
    /// while nothing in here reads a clock or a random number of its own.
    #[test]
    fn the_picture_is_a_pure_function_of_tau_and_seed() {
        for effect in Effect::all() {
            let style = probe_for(effect);
            let mut first = Canvas::new(effect.mapping(), 3, 2, 60);
            let mut again = Canvas::new(effect.mapping(), 3, 2, 60);

            draw(effect, &mut first, 1.37, &style);
            draw(effect, &mut again, 1.37, &style);
            assert_eq!(
                first.image_mut().as_raw(),
                again.image_mut().as_raw(),
                "{effect:?} is not reproducible at the same tau"
            );

            let mut elsewhere = Canvas::new(effect.mapping(), 3, 2, 60);
            let mut reseeded = style;
            reseeded.seed = 7;
            draw(effect, &mut elsewhere, 1.37, &reseeded);
            if effect.knobs().contains(&"seed") {
                assert_ne!(
                    first.image_mut().as_raw(),
                    elsewhere.image_mut().as_raw(),
                    "{effect:?} offers a seed knob that changes nothing"
                );
            }
        }
    }
}

// ============================================================ the knob table
//
// One row per knob name, and a name means one thing everywhere: `scale` is
// always a length multiplier, `density` always a count multiplier. The table
// is where the range, the step and the default live, and `Surface::style`
// reads its clamps from here rather than carrying its own copy, because two
// copies of a range is how an editor ends up with a slider that runs further
// than the daemon will accept and silently stops doing anything near the end.

/// What the editor should put on the row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Control {
    /// A slider between `min` and `max`.
    Range,
    /// One of `options`.
    Choice,
    /// A colour well.
    Color,
    /// A switch.
    Flag,
    /// Two numbers that belong together.
    Pair,
    /// A length of time written the way a person says it: `30s`, `5m`.
    Duration,
}

/// The value a knob has when nobody has set it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Preset {
    Number(f32),
    Text(&'static str),
    Flag(bool),
    Pair([f32; 2]),
    /// The effect decides: `direction`, `mapping` and `fps` differ per effect,
    /// and the catalogue entry already carries each effect's own answer.
    Effect,
}

/// Written as the bare value, so a row reads as `"preset": 1.0` rather than as
/// a tagged union the editor would have to unwrap.
///
/// `Effect` is the one that needs saying out loud. Deriving `untagged` wrote it
/// as `null`, which the editor cannot tell from "this knob has no default",
/// and those mean opposite things: one says go and read the effect's own
/// answer, the other says there is nothing to read. It goes over as the string
/// `"effect"`, which no knob's own default collides with.
impl Serialize for Preset {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeSeq;
        match self {
            Preset::Number(number) => serializer.serialize_f32(*number),
            Preset::Text(text) => serializer.serialize_str(text),
            Preset::Flag(flag) => serializer.serialize_bool(*flag),
            Preset::Pair(pair) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                seq.serialize_element(&pair[0])?;
                seq.serialize_element(&pair[1])?;
                seq.end()
            }
            Preset::Effect => serializer.serialize_str("effect"),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Knob {
    pub name: &'static str,
    pub control: Control,
    pub min: f32,
    pub max: f32,
    pub step: f32,
    #[serde(skip_serializing_if = "<[&str]>::is_empty")]
    pub options: &'static [&'static str],
    pub preset: Preset,
    /// One line for the row, saying what the knob does rather than what it is.
    pub says: &'static str,
}

const fn range(name: &'static str, min: f32, max: f32, step: f32, preset: f32, says: &'static str) -> Knob {
    Knob { name, control: Control::Range, min, max, step, options: &[], preset: Preset::Number(preset), says }
}

const DIRECTIONS: &[&str] = &["right", "left", "up", "down", "cw", "ccw", "out", "in"];

const KNOBS: &[Knob] = &[
    // --- motion
    range("speed", 0.05, 4.0, 0.05, 1.0,
        "How fast it moves. Changing it never makes the picture jump."),
    Knob { name: "direction", control: Control::Choice, min: 0.0, max: 0.0, step: 0.0,
        options: DIRECTIONS, preset: Preset::Effect,
        says: "Which way it travels. Unset means the effect's own axis." },
    Knob { name: "cycle", control: Control::Choice, min: 0.0, max: 0.0, step: 0.0,
        options: &["wrap", "bounce"], preset: Preset::Text("wrap"),
        says: "Start again from the far side, or turn round and come back." },

    // --- size and amount
    range("scale", 0.25, 4.0, 0.05, 1.0,
        "Multiplies every length. This is what decides whether a feature is wider than the seam."),
    range("density", 0.1, 3.0, 0.1, 1.0,
        "How many of them: bars, rings, streaks, stars, blobs."),
    range("softness", 0.0, 1.0, 0.01, 0.55,
        "A hard edge at nothing, feathered across the whole half-width at one."),
    Knob { name: "origin", control: Control::Pair, min: 0.0, max: 1.0, step: 0.01,
        options: &[], preset: Preset::Pair([0.5, 0.5]),
        says: "Where it comes from. The middle is the centre of the seam, so a ring arrives already sixteen pixels across." },

    // --- colour
    Knob { name: "color", control: Control::Color, min: 0.0, max: 0.0, step: 0.0,
        options: &[], preset: Preset::Text("#50a0ff"), says: "The hottest pixels." },
    Knob { name: "color2", control: Control::Color, min: 0.0, max: 0.0, step: 0.0,
        options: &[], preset: Preset::Text(""),
        says: "The second stop. Unset is the first lightened, so two colours look deliberate for free." },
    Knob { name: "background", control: Control::Color, min: 0.0, max: 0.0, step: 0.0,
        options: &[], preset: Preset::Text("#08090c"),
        says: "The fill under everything. A near-black: true black beside lit plastic reads as broken." },
    range("color_cycle", 0.0, 1800.0, 10.0, 0.0,
        "Seconds for one slow drift between the two colours. Off at nothing."),

    // --- light
    range("opacity", 0.0, 1.0, 0.01, 1.0,
        "The master fade. Not the backlight."),
    range("seed", 0.0, 999.0, 1.0, 0.0,
        "A different arrangement with the same character."),

    // --- geometry, clock, manners
    Knob { name: "mapping", control: Control::Choice, min: 0.0, max: 0.0, step: 0.0,
        options: &["physical", "packed"], preset: Preset::Effect,
        says: "Physical keeps shapes true across the gaps; packed keeps a front at constant speed." },
    range("fps", 1.0, 30.0, 1.0, 15.0,
        "Frames a second. Smoothness costs time on the wire, not a busy core."),
    Knob { name: "stop_after", control: Control::Duration, min: 0.0, max: 0.0, step: 0.0,
        options: &[], preset: Preset::Text("0s"),
        says: "Hold the last frame after this long, so a scene you work in settles. Never, at zero." },
    Knob { name: "reduce_motion", control: Control::Flag, min: 0.0, max: 0.0, step: 0.0,
        options: &[], preset: Preset::Flag(true),
        says: "Paint one still frame when macOS asks for less motion." },

    // --- one effect each
    range("shear", -2.0, 2.0, 0.05, 0.0, "Tilts the bar into a diagonal wipe."),
    range("fill", 0.0, 1.0, 0.05, 0.0, "A bare line at nothing, liquid in a tank at a half."),
    range("bands", 0.0, 8.0, 1.0, 0.0, "A smooth field at nothing, soft curtains at three to five."),
    range("wind", -4.0, 4.0, 0.05, 0.0,
        "Sideways drift. Past about four tenths use physical, or the slant kinks at a seam."),
    Knob { name: "lobes", control: Control::Pair, min: 1.0, max: 8.0, step: 1.0,
        options: &[], preset: Preset::Pair([1.0, 1.0]),
        says: "One and one an ellipse, three and two a knot, two and one a figure of eight." },
    range("trail", 0.0, 4.0, 0.05, 0.30,
        "Seconds of the past still drawn. At nothing the head crosses a seam invisibly."),
    range("exponent", 1.0, 4.0, 0.1, 2.4, "A drift at one, perspective at two and a half, a violent jump at four."),
    range("threshold", 0.02, 8.0, 0.02, 1.0,
        "At one a blob ends at its own radius. Lower and everything merges."),
    range("height", 0.05, 1.0, 0.01, 0.75, "How far up the dock the flame reaches."),
    range("smoke", 0.0, 1.0, 0.01, 0.0, "Dissolve the tip into the background."),
    Knob { name: "shape", control: Control::Choice, min: 0.0, max: 0.0, step: 0.0,
        options: &["sine", "ease", "heartbeat"], preset: Preset::Text("sine"),
        says: "Which breath." },
    range("floor", 0.0, 1.0, 0.01, 0.06,
        "The level at the bottom of a breath. Above zero, so the dock never looks switched off."),
];

/// The descriptor for a knob name, or `None` if nothing goes by that name.
pub fn knob(name: &str) -> Option<&'static Knob> {
    KNOBS.iter().find(|knob| knob.name == name)
}

/// The descriptor for a name this crate wrote itself.
///
/// Panics on an unknown name, which `every_knob_an_effect_offers_has_a_row`
/// makes impossible to reach: the only names passed here are the ones the
/// catalogue offers, and that test walks all of them.
pub fn k(name: &'static str) -> &'static Knob {
    knob(name).unwrap_or_else(|| panic!("no knob called {name:?}"))
}

impl Knob {
    /// The value to use, clamped to what the daemon will actually honour.
    pub fn number(&self, value: Option<f32>) -> f32 {
        let fallback = match self.preset {
            Preset::Number(number) => number,
            _ => 0.0,
        };
        value.unwrap_or(fallback).clamp(self.min, self.max)
    }

    pub fn count(&self, value: Option<u8>) -> u8 {
        self.number(value.map(f32::from)).round() as u8
    }

    pub fn pair(&self, value: Option<[f32; 2]>) -> (f32, f32) {
        let fallback = match self.preset {
            Preset::Pair(pair) => pair,
            _ => [0.0, 0.0],
        };
        let pair = value.unwrap_or(fallback);
        (
            pair[0].clamp(self.min, self.max),
            pair[1].clamp(self.min, self.max),
        )
    }
}
