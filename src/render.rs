//! Drawing a key: background, icon, label, and the animation on top of them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use anyhow::{anyhow, Context, Result};
use image::{DynamicImage, Rgb, Rgba, RgbImage, RgbaImage};
use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg;

use std::time::SystemTime;

use crate::config::{Animation, Key};
use crate::icons;
use crate::values::Bindings;

// The face key labels are drawn in is carried in the binary: Inter (SIL Open
// Font License, see `assets/fonts/LICENSE`). Drawn for interfaces, legible at
// the size a 60 px key allows, and carrying the whole of Latin Extended-A,
// which the Serbian alphabet needs. Embedding it also means the dock looks the
// same whatever fonts a Mac happens to have, and that the keys and the app
// share a typeface.

/// The key these measurements are written for.
///
/// Every number below is in pixels of a 60 px key, which is what this dock
/// has. A renderer asked for a larger key multiplies them, so a preview at
/// four times the size is the same picture larger rather than the same
/// picture with tiny text in the corner of a big square.
const REFERENCE_KEY: f32 = 60.0;

/// Label sizes to try, largest first; the first that fits in two lines wins.
const LABEL_SIZES: &[f32] = &[18.0, 16.0, 14.0, 12.0, 11.0, 10.0, 9.0];

/// Sizes a reading is tried at, largest first.
///
/// Chosen by measuring rather than by taste: 54 px of usable width holds three
/// comfortable glyphs at 34 px ("12°" measures 52) and five at 20 ("15:21"
/// measures 50). Six never fit, which is why `%` lives in the caption.
const VALUE_SIZES: &[f32] = &[34.0, 30.0, 26.0, 22.0, 20.0, 18.0];
/// Sizes the line under a reading is tried at, largest first.
///
/// It shrinks rather than wraps or clips: a caption is two or three words and
/// a second line would eat the number, while "GB slobodno" cut to "GB slobodn"
/// looks like the dock gave up halfway.
const CAPTION_SIZES: &[f32] = &[10.0, 9.0, 8.0, 7.0];
/// Height reserved for that line, icon included.
const CAPTION_BAND: i32 = 13;
/// The icon beside a caption. Small on purpose: on a readout the number is the
/// subject and the glyph is the footnote.
const CAPTION_ICON: u32 = 10;

/// What a key is painted when nothing says otherwise.
pub const DEFAULT_BACKGROUND: Rgb<u8> = Rgb([24, 26, 31]);
const MARGIN: i32 = 3;
/// Height reserved for a label drawn under an icon.
const LABEL_BAND: i32 = 15;

/// Where an animation is in its cycle, plus how hard the key is being pressed.
#[derive(Debug, Clone, Copy, Default)]
pub struct Frame {
    /// Seconds since the scene was painted.
    pub time: f32,
    /// 1.0 right after a press, fading to 0.
    pub press: f32,
    /// Which page of how many, when the scene has more than one.
    pub pages: Option<(usize, usize)>,
    /// Which hour of how many, when the scene is being scrubbed.
    pub hour: Option<(usize, usize)>,
}

/// A key's reading, as the daemon worked it out this tick.
///
/// Everything here is already resolved: the templates are filled, the ramp has
/// chosen its colour and the staleness is decided. The renderer's job is the
/// pixels, so that none of the arithmetic happens twice.
#[derive(Debug, Clone)]
pub struct Readout {
    /// The number, drawn as large as it measures.
    pub value: String,
    /// The line under it. When a feed has gone stale this is its age.
    pub caption: String,
    /// A small icon beside the caption, already resolved from its template.
    pub icon: Option<String>,
    /// Degrees to turn that icon, so an arrow can point at the wind.
    pub icon_rotate: f32,
    pub background: Rgb<u8>,
    /// The key's own text colour, when it set one.
    pub foreground: Option<Rgb<u8>>,
    /// False once the reading is past its feed's `stale_after`.
    pub fresh: bool,
}

impl Readout {
    /// A key's reading, resolved from what the feeds have last said.
    ///
    /// The caller has already chosen which of the key's readings this is;
    /// everything else, the templates, the ramp, the staleness, is settled
    /// here, so none of that arithmetic happens twice per frame.
    pub fn of(key: &Key, bindings: &Bindings, now: SystemTime, hours: i32) -> Readout {
        let value = key
            .value
            .as_deref()
            .map(|template| bindings.resolve(template, now, hours));
        let fresh = value.as_ref().map(|resolved| resolved.fresh).unwrap_or(true);

        let caption = if fresh {
            key.caption
                .as_deref()
                .map(|template| bindings.resolve(template, now, hours).text)
                .unwrap_or_default()
        } else {
            // A stale reading says how old it is in place of what it is. The
            // number has not changed; how far behind it is, has.
            bindings.age_caption(key.value.as_deref().unwrap_or_default(), now)
        };

        let background = key
            .ramp
            .as_ref()
            .and_then(|ramp| {
                bindings
                    .number(&ramp.field, now, hours)
                    .and_then(|value| ramp.color(value))
            })
            .or_else(|| key.color.as_deref().and_then(|color| parse_color(color).ok()))
            .unwrap_or(DEFAULT_BACKGROUND);

        Readout {
            value: value.map(|resolved| resolved.text).unwrap_or_default(),
            caption,
            icon: key
                .icon
                .as_deref()
                .map(|template| bindings.resolve(template, now, hours).text)
                .filter(known_icon),
            icon_rotate: key
                .icon_rotate
                .as_deref()
                .and_then(|template| bindings.resolve(template, now, hours).text.parse().ok())
                .unwrap_or(0.0),
            background,
            foreground: key
                .text_color
                .as_deref()
                .and_then(|color| parse_color(color).ok()),
            fresh,
        }
    }
}

/// The key as it can be drawn now, with every template filled in.
///
/// For the keys that are not readings: a label, an icon or a rotation may
/// still come from a feed. A key with nothing live about it is returned as it
/// was written, which is almost all of them.
pub fn fill(key: &Key, bindings: &Bindings, now: SystemTime, hours: i32) -> Key {
    if !key.live() {
        return key.clone();
    }

    let text = |template: &str| bindings.resolve(template, now, hours).text;
    Key {
        label: text(&key.label),
        icon: key.icon.as_deref().map(text).filter(known_icon),
        icon_rotate: key.icon_rotate.as_deref().map(text),
        ..key.clone()
    }
}

/// Whether a name resolved from a feed is one this renderer can draw.
///
/// A feed can produce anything, and an unknown icon makes the renderer refuse
/// the whole key. Dropping it here costs the glyph and keeps the number.
fn known_icon(name: &String) -> bool {
    icons::get(name).is_some() || Path::new(name).exists()
}

impl Default for Readout {
    fn default() -> Readout {
        Readout {
            value: String::new(),
            caption: String::new(),
            icon: None,
            icon_rotate: 0.0,
            background: DEFAULT_BACKGROUND,
            foreground: None,
            fresh: true,
        }
    }
}

impl Frame {
    pub fn at(time: f32) -> Frame {
        Frame {
            time,
            ..Frame::default()
        }
    }
}

/// A rasterised icon, keyed by everything that changes its pixels.
type IconKey = (String, u32, [u8; 3], i32, i32);

pub struct Renderer {
    font: FontVec,
    /// Key image size the device expects, in pixels.
    size: (u32, u32),
    /// Rasterising an icon costs far more than compositing one, and an
    /// animation asks for the same few frames over and over.
    cache: RefCell<HashMap<IconKey, RgbaImage>>,
}

impl Renderer {
    pub fn new(font: Option<&Path>, size: (u32, u32)) -> Result<Renderer> {
        let (path, bytes) = match font {
            Some(path) => {
                let bytes = std::fs::read(path)
                    .with_context(|| format!("reading font {}", path.display()))?;
                (path.display().to_string(), bytes)
            }
            None => (
                "Inter-SemiBold (bundled)".to_string(),
                include_bytes!("../assets/fonts/Inter-SemiBold.ttf").to_vec(),
            ),
        };

        let font = FontVec::try_from_vec(bytes).with_context(|| format!("parsing font {path}"))?;

        Ok(Renderer {
            font,
            size,
            cache: RefCell::new(HashMap::new()),
        })
    }

    /// Key image size this renderer draws for.
    pub fn size(&self) -> (u32, u32) {
        self.size
    }

    /// How much larger than the dock's own key this renderer is drawing.
    fn scale(&self) -> f32 {
        (self.size.1 as f32 / REFERENCE_KEY).max(0.1)
    }

    /// A measurement written for a 60 px key, at this renderer's size.
    fn at(&self, measure: f32) -> f32 {
        measure * self.scale()
    }

    /// Renders a key as it looks at rest.
    pub fn key(&self, key: &Key) -> Result<DynamicImage> {
        self.key_frame(key, Frame::default())
    }

    /// Renders a key at one moment of its animation.
    pub fn key_frame(&self, key: &Key, frame: Frame) -> Result<DynamicImage> {
        let (w, h) = self.size;
        let base = key
            .color
            .as_deref()
            .map(parse_color)
            .transpose()?
            .unwrap_or(DEFAULT_BACKGROUND);

        let background = self.background_for(key, base, frame);
        let mut canvas = RgbImage::from_pixel(w, h, background);

        let foreground = match key.text_color.as_deref() {
            Some(color) => parse_color(color)?,
            None => contrasting(background),
        };

        let mut label_top = self.at(MARGIN as f32).round() as i32;
        if let Some(icon) = &key.icon {
            let color = match key.icon_color.as_deref() {
                Some(color) => parse_color(color)?,
                None => foreground,
            };
            label_top = self.draw_icon(&mut canvas, key, icon, color, frame)?;
        }

        if !key.label.is_empty() {
            self.draw_label(&mut canvas, &key.label, label_top, foreground);
        }

        if let Some((page, pages)) = frame.pages {
            draw_page_strip(&mut canvas, page, pages, foreground);
        }
        if let Some((hour, span)) = frame.hour {
            draw_hour_track(&mut canvas, hour, span, foreground);
        }

        Ok(DynamicImage::ImageRgb8(canvas))
    }

    /// Renders a key as the feeds have it now, whichever way it draws.
    ///
    /// One place decides between a reading and an ordinary key, so the dock
    /// and the preview cannot come to different conclusions about which a
    /// given key is.
    pub fn reading(
        &self,
        key: &Key,
        bindings: &Bindings,
        now: SystemTime,
        hours: i32,
        frame: Frame,
    ) -> Result<DynamicImage> {
        if key.reads() {
            let readout = Readout::of(key, bindings, now, hours);
            // A reading with no number of its own falls through to the
            // ordinary key: that is the sky key, an icon and a line of text.
            if !readout.value.is_empty() {
                return self.readout(&readout, frame);
            }
        }
        self.key_frame(&fill(key, bindings, now, hours), frame)
    }

    /// Renders a key that reports a number.
    ///
    /// The number is the key, so it is drawn as large as it measures with a
    /// caption under it saying what it is. Nothing wraps: a reading that needed
    /// two lines would not be readable across a desk anyway.
    pub fn readout(&self, readout: &Readout, frame: Frame) -> Result<DynamicImage> {
        let (w, h) = self.size;

        let mut background = readout.background;
        if frame.press > 0.0 {
            background = mix(background, Rgb([255, 255, 255]), 0.40 * frame.press);
        }
        let mut foreground = readout.foreground.unwrap_or_else(|| contrasting(background));

        // A stale reading is dimmed, never hidden. The number is still
        // information; a blank key is not, and a bright one would be a lie.
        if !readout.fresh {
            background = scale_color(background, 0.45);
            foreground = scale_color(foreground, 0.45);
        }

        let mut canvas = RgbImage::from_pixel(w, h, background);
        let room = w as f32 - 2.0 * self.at(MARGIN as f32);
        let band = if readout.caption.is_empty() && readout.icon.is_none() {
            0
        } else {
            self.at(CAPTION_BAND as f32).round() as i32
        };

        if !readout.value.is_empty() {
            let scale = self.value_scale(&readout.value, room);
            let x = (w as f32 - self.tabular_width(&readout.value, scale)) / 2.0;
            let field = (h as i32 - band) as f32;
            let baseline = self.centred(&readout.value, scale, field);
            self.draw_glyphs(
                &mut canvas,
                &readout.value,
                (x, baseline),
                scale,
                foreground,
                true,
            );
        }

        if band > 0 {
            self.draw_caption(&mut canvas, readout, band, foreground)?;
        }

        if let Some((page, pages)) = frame.pages {
            draw_page_strip(&mut canvas, page, pages, foreground);
        }
        if let Some((hour, span)) = frame.hour {
            draw_hour_track(&mut canvas, hour, span, foreground);
        }

        Ok(DynamicImage::ImageRgb8(canvas))
    }

    /// The largest size at which this reading fits on one line.
    fn value_scale(&self, value: &str, room: f32) -> PxScale {
        for &size in VALUE_SIZES {
            let scale = PxScale::from(self.at(size));
            if self.tabular_width(value, scale) <= room {
                return scale;
            }
        }
        // Nothing fits, so the smallest is drawn and clipped: a reading cut
        // off still says which way the number is going.
PxScale::from(self.at(*VALUE_SIZES.last().unwrap()))
    }

    /// Draws the caption band: a small icon, then the words.
    fn draw_caption(
        &self,
        canvas: &mut RgbImage,
        readout: &Readout,
        band: i32,
        color: Rgb<u8>,
    ) -> Result<()> {
        let (w, h) = (canvas.width() as i32, canvas.height() as i32);

        let glyph = self.at(CAPTION_ICON as f32).round() as u32;
        let icon_width = match &readout.icon {
            Some(_) if !readout.caption.is_empty() => glyph as i32 + self.at(2.0) as i32,
            Some(_) => glyph as i32,
            None => 0,
        };

        let room = w as f32 - 2.0 * self.at(MARGIN as f32) - icon_width as f32;
        let scale = CAPTION_SIZES
            .iter()
            .map(|size| PxScale::from(self.at(*size)))
            .find(|scale| self.width(&readout.caption, *scale) <= room)
            .unwrap_or_else(|| PxScale::from(self.at(*CAPTION_SIZES.last().unwrap())));
        let text_width = self.width(&readout.caption, scale);
        let total = icon_width as f32 + text_width;
        let mut x = ((w as f32 - total) / 2.0).max(self.at(MARGIN as f32));
        let top = h - band;

        if let Some(icon) = &readout.icon {
            let sprite = self.rasterise(icon, glyph, color, readout.icon_rotate, 1.0)?;
            let y0 = top + (band - glyph as i32) / 2;
            for (sx, sy, px) in sprite.enumerate_pixels() {
                let alpha = f32::from(px[3]) / 255.0;
                if alpha > 0.0 {
                    blend(
                        canvas,
                        x as i32 + sx as i32,
                        y0 + sy as i32,
                        Rgb([px[0], px[1], px[2]]),
                        alpha,
                    );
                }
            }
            x += icon_width as f32;
        }

        if !readout.caption.is_empty() {
            let baseline = top as f32 + self.centred(&readout.caption, scale, band as f32);
            self.draw_line(canvas, &readout.caption, x, baseline, scale, color);
        }

        Ok(())
    }

    /// Background colour for this moment: `blink` drives it, and a press
    /// lightens whatever it produced.
    fn background_for(&self, key: &Key, base: Rgb<u8>, frame: Frame) -> Rgb<u8> {
        let mut color = base;

        if key.animate == Some(Animation::Blink) {
            // Square-ish wave, so it reads as blinking rather than breathing.
            let on = (frame.time * 1.6).sin() > 0.0;
            if !on {
                color = scale_color(color, 0.45);
            }
        }

        if frame.press > 0.0 {
            color = mix(color, Rgb([255, 255, 255]), 0.40 * frame.press);
        }

        color
    }

    /// Draws the icon and returns the y where a label may start.
    fn draw_icon(
        &self,
        canvas: &mut RgbImage,
        key: &Key,
        icon: &str,
        color: Rgb<u8>,
        frame: Frame,
    ) -> Result<i32> {
        let (w, h) = (canvas.width() as i32, canvas.height() as i32);
        let margin = self.at(MARGIN as f32).round() as i32;
        let band = self.at(LABEL_BAND as f32).round() as i32;
        let room = if key.label.is_empty() {
            h - 2 * margin
        } else {
            h - 2 * margin - band
        };
        let box_size = room.max(8) as u32;

        let (scale, rotation) = match key.animate {
            // Breathing: a slow size cycle reads as "alive" without nagging.
            Some(Animation::Pulse) => (0.88 + 0.12 * (0.5 + 0.5 * (frame.time * 2.2).sin()), 0.0),
            Some(Animation::Spin) => (1.0, (frame.time * 150.0) % 360.0),
            _ => (1.0, 0.0),
        };
        // A pressed key grows a little, which reads as a button going down.
        let scale = scale + 0.08 * frame.press;

        let sprite = self.rasterise(icon, box_size, color, rotation, scale)?;

        let x0 = (w - sprite.width() as i32) / 2;
        let y0 = margin;
        for (x, y, px) in sprite.enumerate_pixels() {
            let alpha = f32::from(px[3]) / 255.0;
            if alpha > 0.0 {
                blend(canvas, x0 + x as i32, y0 + y as i32, Rgb([px[0], px[1], px[2]]), alpha);
            }
        }

        Ok(y0 + box_size as i32)
    }

    /// Rasterises an icon, from the bundled set or from a file.
    fn rasterise(
        &self,
        icon: &str,
        size: u32,
        color: Rgb<u8>,
        rotation: f32,
        scale: f32,
    ) -> Result<RgbaImage> {
        // Quantised so an animation reuses frames instead of filling the cache.
        let cache_key: IconKey = (
            icon.to_string(),
            size,
            color.0,
            (rotation * 2.0).round() as i32,
            (scale * 50.0).round() as i32,
        );
        if let Some(hit) = self.cache.borrow().get(&cache_key) {
            return Ok(hit.clone());
        }

        let image = match icons::get(icon) {
            Some(svg) => render_svg(svg, size, color, rotation, scale)?,
            None => {
                let path = Path::new(icon);
                if !path.exists() {
                    return Err(anyhow!(
                        "unknown icon {icon:?}: not a bundled icon and not a file. \
                         Bundled: {}",
                        icons::names().join(", ")
                    ));
                }
                if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("svg")) {
                    let svg = std::fs::read_to_string(path)
                        .with_context(|| format!("reading icon {icon}"))?;
                    render_svg(&svg, size, color, rotation, scale)?
                } else {
                    image::open(path)
                        .with_context(|| format!("reading icon {icon}"))?
                        .thumbnail(size, size)
                        .to_rgba8()
                }
            }
        };

        self.cache.borrow_mut().insert(cache_key, image.clone());
        Ok(image)
    }

    /// Draws the label, shrinking and wrapping it until it fits below `top`.
    fn draw_label(&self, canvas: &mut RgbImage, label: &str, top: i32, color: Rgb<u8>) {
        let margin = self.at(MARGIN as f32);
        let max_width = canvas.width() as f32 - 2.0 * margin;
        let max_height = canvas.height() as f32 - top as f32 - margin;

        let mut chosen = None;
        for &size in LABEL_SIZES {
            let scale = PxScale::from(self.at(size));
            let font = self.font.as_scaled(scale);
            let lines = wrap(label, |text| self.width(text, scale), max_width);
            let total = font.height() * lines.len() as f32;

            let fits =
                total <= max_height && lines.iter().all(|l| self.width(l, scale) <= max_width);
            if fits {
                chosen = Some((scale, lines));
                break;
            }
            // Keep the smallest attempt as a fallback: an over-long label is
            // better clipped than not drawn at all.
            if size == *LABEL_SIZES.last().unwrap() {
                chosen = Some((scale, lines));
            }
        }

        let Some((scale, lines)) = chosen else { return };
        let font = self.font.as_scaled(scale);
        let line_height = font.height();
        let block = line_height * lines.len() as f32;
        let mut baseline = top as f32 + (max_height - block).max(0.0) / 2.0 + font.ascent();

        for line in lines {
            let x = (canvas.width() as f32 - self.width(&line, scale)) / 2.0;
            self.draw_line(canvas, &line, x, baseline, scale, color);
            baseline += line_height;
        }
    }

    fn draw_line(
        &self,
        canvas: &mut RgbImage,
        text: &str,
        x: f32,
        baseline: f32,
        scale: PxScale,
        color: Rgb<u8>,
    ) {
        self.draw_glyphs(canvas, text, (x, baseline), scale, color, false);
    }

    /// Draws a line, optionally giving every digit the same advance.
    ///
    /// Inter's figures are proportional, `1` measures 0.349 em against `0` at
    /// 0.545, so a reading going from 11 to 12 would shift sideways under
    /// your eye, which on a number that updates reads as the dock twitching.
    /// The face has tabular figures, but reaching them needs OpenType feature
    /// application that this renderer does not do, so the advance is equalised
    /// here and each digit is centred in its own slot.
    fn draw_glyphs(
        &self,
        canvas: &mut RgbImage,
        text: &str,
        at: (f32, f32),
        scale: PxScale,
        color: Rgb<u8>,
        tabular: bool,
    ) {
        let (x, baseline) = at;
        let font = self.font.as_scaled(scale);
        let slot = tabular.then(|| self.digit_advance(scale));
        let mut caret = x;

        for ch in text.chars() {
            let id = font.glyph_id(ch);
            let advance = font.h_advance(id);
            let (step, offset) = match slot {
                Some(slot) if ch.is_ascii_digit() => (slot, (slot - advance) / 2.0),
                _ => (advance, 0.0),
            };
            let glyph =
                id.with_scale_and_position(scale, ab_glyph::point(caret + offset, baseline));
            caret += step;

            if let Some(outline) = font.outline_glyph(glyph) {
                let bounds = outline.px_bounds();
                outline.draw(|gx, gy, coverage| {
                    if coverage > 0.0 {
                        blend(
                            canvas,
                            bounds.min.x as i32 + gx as i32,
                            bounds.min.y as i32 + gy as i32,
                            color,
                            coverage.min(1.0),
                        );
                    }
                });
            }
        }
    }

    /// The baseline that centres this text's own ink in a field `height` tall.
    ///
    /// Measured rather than taken from the face's metrics. A reading has no
    /// descenders to balance, so centring on the line height sits it visibly
    /// high, and `°` reaches above the cap line, which no metric reports.
    fn centred(&self, text: &str, scale: PxScale, height: f32) -> f32 {
        match self.ink(text, scale) {
            Some((top, bottom)) => (height - (bottom - top)) / 2.0 - top,
            None => {
                let font = self.font.as_scaled(scale);
                (height - font.height()) / 2.0 + font.ascent()
            }
        }
    }

    /// How far this text's ink reaches above and below the baseline.
    fn ink(&self, text: &str, scale: PxScale) -> Option<(f32, f32)> {
        let font = self.font.as_scaled(scale);
        let mut top = f32::INFINITY;
        let mut bottom = f32::NEG_INFINITY;
        let mut caret = 0.0;

        for ch in text.chars() {
            let id = font.glyph_id(ch);
            let glyph = id.with_scale_and_position(scale, ab_glyph::point(caret, 0.0));
            caret += font.h_advance(id);
            if let Some(outline) = font.outline_glyph(glyph) {
                let bounds = outline.px_bounds();
                top = top.min(bounds.min.y);
                bottom = bottom.max(bounds.max.y);
            }
        }

        (top.is_finite() && bottom.is_finite()).then_some((top, bottom))
    }

    fn width(&self, text: &str, scale: PxScale) -> f32 {
        let font = self.font.as_scaled(scale);
        text.chars().map(|c| font.h_advance(font.glyph_id(c))).sum()
    }

    /// The advance every digit is given, which is the widest of them.
    fn digit_advance(&self, scale: PxScale) -> f32 {
        let font = self.font.as_scaled(scale);
        ('0'..='9')
            .map(|c| font.h_advance(font.glyph_id(c)))
            .fold(0.0, f32::max)
    }

    /// How wide this text is once the digits are equalised.
    fn tabular_width(&self, text: &str, scale: PxScale) -> f32 {
        let font = self.font.as_scaled(scale);
        let slot = self.digit_advance(scale);
        text.chars()
            .map(|c| {
                if c.is_ascii_digit() {
                    slot
                } else {
                    font.h_advance(font.glyph_id(c))
                }
            })
            .sum()
    }
}

/// Draws the page indicator: a hairline along the top of every key, split into
/// one segment per page.
///
/// It sits on every key rather than one, so the whole dock reads as a single
/// strip and the indicator cannot land on a key the page happens to leave empty.
fn draw_page_strip(canvas: &mut RgbImage, page: usize, pages: usize, color: Rgb<u8>) {
    if pages < 2 {
        return;
    }

    let width = canvas.width() as f32;
    let scale = (canvas.height() as f32 / REFERENCE_KEY).max(0.1);
    let gap = 2.0 * scale;
    let thickness = (2.0 * scale).round().max(1.0) as i32;
    let segment = (width - gap * (pages as f32 + 1.0)) / pages as f32;
    if segment < 1.0 {
        return;
    }

    for index in 0..pages {
        let x0 = gap + index as f32 * (segment + gap);
        let alpha = if index == page { 0.95 } else { 0.22 };
        for x in x0.round() as i32..(x0 + segment).round() as i32 {
            for y in 0..thickness {
                blend(canvas, x, y, color, alpha);
            }
        }
    }
}

/// One bundled icon, rasterised to a square.
///
/// Exposed because the dock sometimes draws a picture that is not a key: the
/// volume meter marks mute with a speaker, and rasterising it here keeps one
/// renderer rather than two that could disagree about what an icon looks like.
pub fn sprite(name: &str, size: u32, color: Rgb<u8>) -> Result<RgbaImage> {
    let svg = icons::get(name).ok_or_else(|| anyhow!("unknown icon {name:?}"))?;
    render_svg(svg, size, color, 0.0, 1.0)
}

/// Draws the forecast scrub: a dim track along the top of every key, with a
/// bright tick at the hour being read.
///
/// Not the page strip. Twenty-four segments across a 60 px key work out at
/// 0.42 px each, which rounds away to nothing; a continuous track with a tick
/// says the same thing and survives the arithmetic. The tick is placed and
/// covered fractionally, so an hour never snaps to the wrong pixel.
fn draw_hour_track(canvas: &mut RgbImage, hour: usize, span: usize, color: Rgb<u8>) {
    if span < 2 {
        return;
    }

    let scale = (canvas.height() as f32 / REFERENCE_KEY).max(0.1);
    let tick = 5.0 * scale;
    let thickness = (2.0 * scale).round().max(1.0) as i32;

    let width = canvas.width() as f32;
    for x in 0..canvas.width() as i32 {
        for y in 0..thickness {
            blend(canvas, x, y, color, 0.14);
        }
    }

    let fraction = (hour as f32 / (span - 1) as f32).clamp(0.0, 1.0);
    let start = fraction * (width - tick);
    let end = start + tick;
    for x in start.floor() as i32..=end.ceil() as i32 {
        let left = (x as f32).max(start);
        let right = ((x + 1) as f32).min(end);
        let coverage = (right - left).clamp(0.0, 1.0);
        if coverage > 0.0 {
            for y in 0..thickness {
                blend(canvas, x, y, color, 0.95 * coverage);
            }
        }
    }
}

/// Rasterises an SVG into a square, recoloured and transformed about its centre.
fn render_svg(svg: &str, size: u32, color: Rgb<u8>, rotation: f32, scale: f32) -> Result<RgbaImage> {
    // Lucide icons are stroked with `currentColor`, which has no meaning
    // outside a document, so the colour is substituted before parsing.
    let painted = svg.replace(
        "currentColor",
        &format!("#{:02x}{:02x}{:02x}", color[0], color[1], color[2]),
    );

    let tree = usvg::Tree::from_str(&painted, &usvg::Options::default())
        .context("parsing icon SVG")?;

    let mut pixmap = Pixmap::new(size, size).context("icon size is zero")?;
    let view = tree.size();
    let fit = (size as f32 / view.width()).min(size as f32 / view.height()) * scale;
    let centre = size as f32 / 2.0;

    let transform = Transform::from_translate(centre, centre)
        .pre_rotate(rotation)
        .pre_scale(fit, fit)
        .pre_translate(-view.width() / 2.0, -view.height() / 2.0);

    resvg::render(&tree, transform, &mut pixmap.as_mut());

    let mut image = RgbaImage::new(size, size);
    for (pixel, out) in pixmap.pixels().iter().zip(image.pixels_mut()) {
        let c = pixel.demultiply();
        *out = Rgba([c.red(), c.green(), c.blue(), c.alpha()]);
    }

    Ok(image)
}

/// Greedy word wrap, falling back to whole words that are too long on their own.
fn wrap(text: &str, width_of: impl Fn(&str) -> f32, max: f32) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for word in text.split_whitespace() {
        match lines.last_mut() {
            Some(line) => {
                let candidate = format!("{line} {word}");
                if width_of(&candidate) <= max {
                    *line = candidate;
                } else {
                    lines.push(word.to_string());
                }
            }
            None => lines.push(word.to_string()),
        }
    }

    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// Parses `#RRGGBB` or `#RGB`.
pub fn parse_color(text: &str) -> Result<Rgb<u8>> {
    let hex = text.trim().trim_start_matches('#');
    let value =
        u32::from_str_radix(hex, 16).with_context(|| format!("colour {text:?} is not hex"))?;

    match hex.len() {
        6 => Ok(Rgb([
            (value >> 16) as u8,
            ((value >> 8) & 0xFF) as u8,
            (value & 0xFF) as u8,
        ])),
        3 => Ok(Rgb([
            (((value >> 8) & 0xF) * 17) as u8,
            (((value >> 4) & 0xF) * 17) as u8,
            ((value & 0xF) * 17) as u8,
        ])),
        _ => Err(anyhow!("colour {text:?} must be #RGB or #RRGGBB")),
    }
}

/// Black on light backgrounds, white on dark ones.
fn contrasting(background: Rgb<u8>) -> Rgb<u8> {
    let [r, g, b] = background.0.map(f32::from);
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if luma > 140.0 {
        Rgb([16, 16, 16])
    } else {
        Rgb([245, 245, 245])
    }
}

fn scale_color(color: Rgb<u8>, factor: f32) -> Rgb<u8> {
    Rgb(color.0.map(|c| (f32::from(c) * factor).round().clamp(0.0, 255.0) as u8))
}

pub fn mix(a: Rgb<u8>, b: Rgb<u8>, t: f32) -> Rgb<u8> {
    let t = t.clamp(0.0, 1.0);
    let mut out = [0u8; 3];
    for i in 0..3 {
        out[i] = (f32::from(a[i]) + (f32::from(b[i]) - f32::from(a[i])) * t).round() as u8;
    }
    Rgb(out)
}

fn blend(canvas: &mut RgbImage, x: i32, y: i32, color: Rgb<u8>, alpha: f32) {
    if x < 0 || y < 0 || x >= canvas.width() as i32 || y >= canvas.height() as i32 {
        return;
    }

    let px = canvas.get_pixel_mut(x as u32, y as u32);
    for i in 0..3 {
        let base = f32::from(px[i]);
        px[i] = (base + (f32::from(color[i]) - base) * alpha).round() as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colors() {
        assert_eq!(parse_color("#ff8000").unwrap(), Rgb([255, 128, 0]));
        assert_eq!(parse_color("#f80").unwrap(), Rgb([255, 136, 0]));
        assert!(parse_color("#ff80").is_err());
    }

    #[test]
    fn text_contrast_follows_background() {
        assert_eq!(contrasting(Rgb([250, 250, 250])), Rgb([16, 16, 16]));
        assert_eq!(contrasting(Rgb([20, 20, 20])), Rgb([245, 245, 245]));
    }

    #[test]
    fn wrapping_breaks_on_width() {
        let lines = wrap("one two three", |t| t.len() as f32, 7.0);
        assert_eq!(lines, vec!["one two", "three"]);
    }

    /// Mean brightness of the ink, so two renders can be compared.
    fn luma(image: &DynamicImage) -> f32 {
        let image = image.to_rgb8();
        let total: f32 = image
            .pixels()
            .map(|p| 0.299 * f32::from(p[0]) + 0.587 * f32::from(p[1]) + 0.114 * f32::from(p[2]))
            .sum();
        total / image.pixels().len() as f32
    }

    #[test]
    fn a_reading_is_drawn_as_large_as_it_measures() {
        let renderer = Renderer::new(None, (60, 60)).expect("a renderer");
        let room = 60.0 - 2.0 * MARGIN as f32;
        // Four times the key is the same picture four times over, not the
        // same picture with tiny text in the corner of a big square.
        let large = Renderer::new(None, (240, 240)).expect("a renderer");
        assert_eq!(
            large.value_scale("12\u{b0}", room * 4.0).y,
            renderer.value_scale("12\u{b0}", room).y * 4.0
        );

        // Three glyphs take the top of the ladder, which is the whole point of
        // the ladder: a temperature should be readable across a desk.
        assert_eq!(renderer.value_scale("12°", room).y, 34.0);
        assert_eq!(renderer.value_scale("5.8", room).y, 34.0);

        // Equalised digits are wider than the face's own, so a number keeps
        // the same width as it changes.
        let scale = PxScale::from(34.0);
        assert!(renderer.tabular_width("11", scale) == renderer.tabular_width("12", scale));
        assert!(renderer.tabular_width("11", scale) > renderer.width("11", scale));

        // Five land lower, and every size on the ladder must actually fit.
        let five = renderer.value_scale("15:21", room).y;
        assert!((20.0..=22.0).contains(&five), "five glyphs landed at {five}");
        for text in ["12°", "5.8", "15:21", "-12", "100"] {
            let scale = renderer.value_scale(text, room);
            assert!(
                renderer.tabular_width(text, scale) <= room,
                "{text:?} at {} overflows the key",
                scale.y
            );
        }
    }

    #[test]
    fn a_stale_reading_is_dimmer_but_still_there() {
        let renderer = Renderer::new(None, (60, 60)).expect("a renderer");
        let reading = Readout {
            value: "12°".into(),
            caption: "oseća 10°".into(),
            background: Rgb([30, 80, 140]),
            ..Readout::default()
        };
        let fresh = renderer.readout(&reading, Frame::default()).expect("fresh");
        let stale = renderer
            .readout(
                &Readout {
                    fresh: false,
                    ..reading.clone()
                },
                Frame::default(),
            )
            .expect("stale");

        assert!(luma(&stale) < luma(&fresh), "a stale reading is dimmed");
        // And it is still a reading, not a blanked key: the number is the one
        // thing that must survive a host going quiet.
        let blank = renderer
            .readout(
                &Readout {
                    value: String::new(),
                    caption: String::new(),
                    ..reading
                },
                Frame::default(),
            )
            .expect("blank");
        assert!(luma(&stale) != luma(&blank));
    }

    #[test]
    fn the_hour_track_draws_where_a_page_strip_would_vanish() {
        // Twenty-four segments across 60 px is 0.42 px each, so the strip
        // refuses to draw. This is the case the track exists for.
        let mut canvas = RgbImage::from_pixel(60, 60, Rgb([0, 0, 0]));
        draw_page_strip(&mut canvas, 3, 24, Rgb([255, 255, 255]));
        assert!(
            canvas.pixels().all(|p| p[0] == 0),
            "a 24-page strip cannot be drawn"
        );

        let mut canvas = RgbImage::from_pixel(60, 60, Rgb([0, 0, 0]));
        draw_hour_track(&mut canvas, 3, 24, Rgb([255, 255, 255]));
        let top: Vec<u8> = (0..60).map(|x| canvas.get_pixel(x, 0)[0]).collect();
        assert!(top.iter().any(|v| *v > 200), "the tick is bright");
        assert!(
            top.iter().filter(|v| **v > 0 && **v < 100).count() > 40,
            "and the rest is a dim track"
        );

        // The tick moves with the hour, and never off the key.
        let position = |hour: usize| {
            let mut canvas = RgbImage::from_pixel(60, 60, Rgb([0, 0, 0]));
            draw_hour_track(&mut canvas, hour, 24, Rgb([255, 255, 255]));
            (0..60)
                .max_by_key(|x| canvas.get_pixel(*x, 0)[0])
                .expect("a brightest pixel")
        };
        assert!(position(0) < position(12), "it moves forward");
        assert!(position(12) < position(23));
        assert!(position(23) < 60);
    }

    #[test]
    fn every_bundled_icon_renders() {
        for name in icons::names() {
            let svg = icons::get(name).expect("listed icon exists");
            let image = render_svg(svg, 40, Rgb([255, 255, 255]), 0.0, 1.0)
                .unwrap_or_else(|e| panic!("icon {name} failed: {e}"));
            let ink = image.pixels().filter(|p| p[3] > 0).count();
            assert!(ink > 0, "icon {name} rendered blank");
        }
    }
}

