//! The dock as one display.
//!
//! Six 60x60 screens with plastic between them are not a 180x120 image. The
//! gaps are real: about a quarter of a key wide, so a drawing that ignores them
//! shears at every seam. A canvas is therefore larger than the sum of its keys,
//! and each key is a window cut out of it at the right offset.
//!
//! Which is right depends on what is being drawn:
//!
//! * `Physical` keeps true geometry — a circle stays round, a diagonal stays
//!   straight — at the cost that a travelling front disappears for the width of
//!   each bezel. Right for rings, orbits and anything with a shape.
//! * `Packed` ignores the gaps, so a front crosses the dock at constant
//!   apparent speed and never stalls. Right for sweeps and meters.
//!
//! Static text and photographs belong on neither: a letter cut by 15 px of
//! plastic is a letter gone.

use image::{Rgb, RgbImage};
use serde::{Deserialize, Serialize};

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

/// What the canvas does over time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effect {
    /// A bright band crossing the dock.
    Sweep,
    /// A travelling sine, drawn as a lit crest.
    Wave,
    /// A ring expanding from the middle.
    Pulse,
    /// Falling streaks.
    Rain,
    /// Slow drifting colour, with nothing to track.
    Aurora,
}

impl Effect {
    /// The mapping this effect is drawn in unless the config says otherwise.
    pub fn mapping(self) -> Mapping {
        match self {
            // A front that stalls at every bezel reads as a stutter, so these
            // are drawn as though the keys were butted together.
            Effect::Sweep | Effect::Wave | Effect::Rain => Mapping::Packed,
            // These have a shape, and a shape must survive the gaps.
            Effect::Pulse | Effect::Aurora => Mapping::Physical,
        }
    }

    /// Frames per second this effect wants.
    pub fn fps(self) -> u8 {
        match self {
            Effect::Aurora => 8,
            _ => 15,
        }
    }

    /// How long until the motion repeats, in seconds.
    ///
    /// Used to decide how many frames a preview needs. Two of these do not
    /// truly repeat, so they report a length that looks like a loop instead of
    /// pretending to be one.
    pub fn period(self) -> f32 {
        match self {
            Effect::Sweep => 2.6,
            Effect::Wave => 1.0 / 1.7,
            Effect::Pulse => 2.2,
            Effect::Rain => 4.0,
            Effect::Aurora => 8.0,
        }
    }

    /// Every effect, in the order a gallery should show them.
    pub fn all() -> [Effect; 5] {
        [
            Effect::Sweep,
            Effect::Wave,
            Effect::Pulse,
            Effect::Rain,
            Effect::Aurora,
        ]
    }

    pub fn name(self) -> &'static str {
        match self {
            Effect::Sweep => "sweep",
            Effect::Wave => "wave",
            Effect::Pulse => "pulse",
            Effect::Rain => "rain",
            Effect::Aurora => "aurora",
        }
    }
}

/// Draws one frame. `time` is seconds since the scene was painted.
pub fn draw(effect: Effect, canvas: &mut Canvas, time: f32, tint: Rgb<u8>, background: Rgb<u8>) {
    canvas.fill(background);

    let width = canvas.width() as f32;
    let height = canvas.height() as f32;

    match effect {
        Effect::Sweep => {
            // A band of light, three keys wide at its brightest, wrapping.
            let period = 2.6;
            let head = ((time % period) / period) * (width + 80.0) - 40.0;
            let tail = 46.0;

            for x in 0..canvas.width() {
                let distance = head - x as f32;
                if distance < 0.0 || distance > tail {
                    continue;
                }
                let strength = (1.0 - distance / tail).powi(2);
                for y in 0..canvas.height() {
                    canvas.blend(x as i32, y as i32, tint, strength);
                }
            }
        }

        Effect::Wave => {
            let speed = 1.7;
            let wavelength = width / 1.6;
            for x in 0..canvas.width() {
                let phase = (x as f32 / wavelength - time * speed) * std::f32::consts::TAU;
                let crest = height * 0.5 + phase.sin() * height * 0.28;
                for y in 0..canvas.height() {
                    let distance = (y as f32 - crest).abs();
                    let strength = (1.0 - distance / 12.0).max(0.0).powi(2);
                    if strength > 0.0 {
                        canvas.blend(x as i32, y as i32, tint, strength);
                    }
                }
            }
        }

        Effect::Pulse => {
            // Rings leaving the middle. Drawn in physical geometry so they stay
            // round across the bezels.
            let centre = (width / 2.0, height / 2.0);
            let period = 2.2;
            let largest = (width * width + height * height).sqrt() / 2.0;

            for ring in 0..3 {
                let offset = ring as f32 / 3.0;
                let progress = ((time / period) + offset).fract();
                let radius = progress * largest;
                let fade = 1.0 - progress;

                for y in 0..canvas.height() {
                    for x in 0..canvas.width() {
                        let dx = x as f32 - centre.0;
                        let dy = y as f32 - centre.1;
                        let distance = (dx * dx + dy * dy).sqrt();
                        let strength = (1.0 - (distance - radius).abs() / 7.0).max(0.0);
                        if strength > 0.0 {
                            canvas.blend(x as i32, y as i32, tint, strength * fade * 0.9);
                        }
                    }
                }
            }
        }

        Effect::Rain => {
            // Deterministic streaks: no randomness, so a resumed frame looks
            // like the frame before it.
            let columns = 14;
            for column in 0..columns {
                let seed = (column as f32 * 12.9898).sin() * 43758.547;
                let offset = seed.fract().abs();
                let speed = 28.0 + offset * 46.0;
                let x = (offset * width + column as f32 * (width / columns as f32)) % width;
                let head = ((time * speed + offset * height) % (height + 30.0)) - 15.0;

                for step in 0..18 {
                    let y = head - step as f32;
                    let strength = (1.0 - step as f32 / 18.0).powi(2);
                    canvas.blend(x as i32, y as i32, tint, strength);
                    canvas.blend(x as i32 + 1, y as i32, tint, strength * 0.45);
                }
            }
        }

        Effect::Aurora => {
            // Two slow fields crossing, so nothing repeats on an obvious beat.
            for y in 0..canvas.height() {
                for x in 0..canvas.width() {
                    let fx = x as f32 / width;
                    let fy = y as f32 / height;
                    let a = (fx * 2.4 + time * 0.23).sin();
                    let b = (fy * 3.1 - time * 0.17).cos();
                    let strength = ((a + b) * 0.25 + 0.5).clamp(0.0, 1.0) * 0.55;
                    canvas.blend(x as i32, y as i32, tint, strength);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        for effect in [
            Effect::Sweep,
            Effect::Wave,
            Effect::Pulse,
            Effect::Rain,
            Effect::Aurora,
        ] {
            let mut canvas = Canvas::new(effect.mapping(), 3, 2, 60);
            // Sampled over a second: a sweep is dark at some instants by design.
            let lit = (0..16)
                .map(|step| {
                    draw(
                        effect,
                        &mut canvas,
                        step as f32 / 16.0,
                        Rgb([80, 160, 255]),
                        Rgb([0, 0, 0]),
                    );
                    canvas.image_mut().pixels().filter(|p| p[2] > 10).count()
                })
                .max()
                .unwrap_or(0);
            assert!(lit > 100, "{effect:?} drew almost nothing");
        }
    }
}
