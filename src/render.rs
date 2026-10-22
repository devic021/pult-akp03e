//! Drawing a key: background, icon, label, and the animation on top of them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use anyhow::{anyhow, Context, Result};
use image::{DynamicImage, Rgb, Rgba, RgbImage, RgbaImage};
use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg;

use crate::config::{Animation, Key};
use crate::icons;

/// Fonts to try when the config names none. All ship with macOS.
const FONT_CANDIDATES: &[&str] = &[
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Geneva.ttf",
];

/// Label sizes to try, largest first; the first that fits in two lines wins.
const LABEL_SIZES: &[f32] = &[18.0, 16.0, 14.0, 12.0, 11.0, 10.0, 9.0];

const DEFAULT_BACKGROUND: Rgb<u8> = Rgb([24, 26, 31]);
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
            None => FONT_CANDIDATES
                .iter()
                .find_map(|c| std::fs::read(c).ok().map(|b| ((*c).to_string(), b)))
                .ok_or_else(|| {
                    anyhow!("no usable system font found; set `font` in the config")
                })?,
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

        let mut label_top = MARGIN;
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

        Ok(DynamicImage::ImageRgb8(canvas))
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
        let room = if key.label.is_empty() {
            h - 2 * MARGIN
        } else {
            h - 2 * MARGIN - LABEL_BAND
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
        let y0 = MARGIN;
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
        let max_width = canvas.width() as f32 - 2.0 * MARGIN as f32;
        let max_height = canvas.height() as f32 - top as f32 - MARGIN as f32;

        let mut chosen = None;
        for &size in LABEL_SIZES {
            let scale = PxScale::from(size);
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
        let font = self.font.as_scaled(scale);
        let mut caret = x;

        for ch in text.chars() {
            let id = font.glyph_id(ch);
            let glyph = id.with_scale_and_position(scale, ab_glyph::point(caret, baseline));
            caret += font.h_advance(id);

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

    fn width(&self, text: &str, scale: PxScale) -> f32 {
        let font = self.font.as_scaled(scale);
        text.chars().map(|c| font.h_advance(font.glyph_id(c))).sum()
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
    let gap = 2.0;
    let segment = (width - gap * (pages as f32 + 1.0)) / pages as f32;
    if segment < 1.0 {
        return;
    }

    for index in 0..pages {
        let x0 = gap + index as f32 * (segment + gap);
        let alpha = if index == page { 0.95 } else { 0.22 };
        for x in x0.round() as i32..(x0 + segment).round() as i32 {
            for y in 0..2 {
                blend(canvas, x, y, color, alpha);
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

fn mix(a: Rgb<u8>, b: Rgb<u8>, t: f32) -> Rgb<u8> {
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
