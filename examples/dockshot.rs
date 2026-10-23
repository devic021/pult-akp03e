//! The dock as the app draws it, for the README.
//!
//!   dockshot <scene> <out.png> [config.toml]
//!
//! The proportions are the ones in `DeviceCanvas.swift`, measured off the
//! device with a body 640 wide, so the picture in the README and the drawing
//! in the editor are the same object. The keys are rendered at the size they
//! appear at rather than at sixty pixels and blown up: the renderer scales its
//! own measurements, so a larger key is the same picture larger.

use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use image::{Rgb, RgbImage};
use pult::config::{self, Config};
use pult::feed;
use pult::render::{Frame, Renderer};
use pult::values::Bindings;
use std::time::SystemTime;

/// Everything derives from this, as it does in the app.
const F: f32 = 1.5;
const fn u(value: f32) -> f32 {
    value * F
}

fn main() -> anyhow::Result<()> {
    let scene_name = std::env::args().nth(1).unwrap();
    let out = std::env::args().nth(2).unwrap();
    let path = config::resolve_path(std::env::args().nth(3).as_deref())?;

    let config = Config::load(&path)?;
    let scene = config.scene(&scene_name).expect("a scene");
    let font = FontVec::try_from_vec(std::fs::read("assets/fonts/Inter-SemiBold.ttf")?)?;

    let (body_w, body_h) = (u(640.0), u(376.0));
    let margin = u(16.0);
    let mut img = RgbImage::from_pixel(
        (body_w + margin * 2.0) as u32,
        (body_h + margin * 2.0) as u32,
        Rgb([10, 10, 12]),
    );

    // The shell: a vertical gradient, and one bright line along the top edge,
    // which is the cue that turns a grey rectangle into a moulded thing.
    let corner = u(26.0);
    rounded(&mut img, margin, margin, body_w, body_h, corner, &|_, t| {
        let shade = if t < 0.5 {
            0.21 + (0.135 - 0.21) * (t / 0.5)
        } else {
            0.135 + (0.115 - 0.135) * ((t - 0.5) / 0.5)
        };
        (grey(shade), 1.0)
    });
    rounded_edge(&mut img, margin, margin, body_w, body_h, corner, u(1.2));

    badge(&mut img, &font, margin + body_w / 2.0, margin + u(26.0));

    // The screens, in their caps.
    let key = u(80.0);
    let gap = u(10.0);
    let bezel = u(4.0);
    let origin = (margin + u(74.0), margin + u(52.0));

    let renderer = Renderer::new(
        config.font.as_deref(),
        ((key - bezel * 2.0) as u32, (key - bezel * 2.0) as u32),
    )?;

    let mut bindings = Bindings::new();
    let places = feed::places();
    for (name, spec) in &config.feeds {
        bindings.declare(name, spec.stale_after());
        if let Ok(sample) = spec
            .target(&places)
            .and_then(|target| feed::poll(spec, &target, SystemTime::now()))
        {
            bindings.put(name, sample);
        }
    }

    let now = SystemTime::now();
    for slot in 0..6u32 {
        let (row, column) = (slot / 3, slot % 3);
        let x = origin.0 + column as f32 * (key + gap);
        let y = origin.1 + row as f32 * (key + gap);

        // The cap the display is moulded into.
        rounded(&mut img, x, y, key, key, u(10.0), &|_, t| {
            (grey(0.09 + 0.05 * (1.0 - t)), 1.0)
        });

        let Some(spec) = scene.keys.get(slot as usize) else {
            continue;
        };
        let tile = renderer
            .reading(spec, &bindings, now, 0, Frame::default())?
            .to_rgb8();
        for (tx, ty, px) in tile.enumerate_pixels() {
            let (px_x, px_y) = ((x + bezel) as u32 + tx, (y + bezel) as u32 + ty);
            if px_x < img.width() && px_y < img.height() {
                img.put_pixel(px_x, px_y, *px);
            }
        }
    }

    // The knobs and the buttons, where the device has them.
    let big = (margin + u(476.0), margin + u(124.0));
    knob(&mut img, big.0, big.1, u(146.0) / 2.0);
    label(&mut img, &font, "Big knob", big.0, big.1 + u(146.0) / 2.0 + u(14.0));

    for (index, cx) in [u(113.0), u(206.0), u(299.0)].iter().enumerate() {
        let (x, y) = (margin + cx, margin + u(300.0));
        button(&mut img, x, y, u(58.0) / 2.0);
        label(&mut img, &font, &format!("{}", index + 1), x, y + u(58.0) / 2.0 + u(14.0));
    }

    for (cx, name) in [(u(420.0), "Small left knob"), (u(532.0), "Small right knob")] {
        let (x, y) = (margin + cx, margin + u(300.0));
        knob(&mut img, x, y, u(70.0) / 2.0);
        label(&mut img, &font, name, x, y + u(70.0) / 2.0 + u(14.0));
    }

    img.save(&out)?;
    println!("{out}: {}x{}", img.width(), img.height());
    Ok(())
}

fn grey(shade: f32) -> Rgb<u8> {
    let v = (shade.clamp(0.0, 1.0) * 255.0).round() as u8;
    Rgb([v, v, v])
}

/// Our mark where the manufacturer's goes: the same six keys as the icon, in
/// grey because this is paint on plastic rather than a lit display, and the
/// name set the way a wordmark is.
fn badge(img: &mut RgbImage, font: &FontVec, cx: f32, cy: f32) {
    let key = u(19.0) / 3.6;
    let gap = key * 0.26;
    let mark_w = 3.0 * key + 2.0 * gap;
    let text = "PULT";
    let size = u(13.0);
    let tracking = u(6.0);
    let text_w = width_of(font, text, size, tracking);
    let total = mark_w + u(7.0) + text_w;

    let x0 = cx - total / 2.0;
    let y0 = cy - (2.0 * key + gap) / 2.0;
    for row in 0..2 {
        for column in 0..3 {
            let lit = row == 0 && column == 1;
            let x = x0 + column as f32 * (key + gap);
            let y = y0 + row as f32 * (key + gap);
            rounded(img, x, y, key, key, key * 0.26, &|_, _| {
                (Rgb([255, 255, 255]), if lit { 0.52 } else { 0.22 })
            });
        }
    }

    draw_text(
        img,
        font,
        text,
        x0 + mark_w + u(7.0),
        cy + size * 0.36,
        size,
        tracking,
        Rgb([255, 255, 255]),
        0.34,
    );
}

fn label(img: &mut RgbImage, font: &FontVec, text: &str, cx: f32, y: f32) {
    let size = u(9.0);
    let w = width_of(font, text, size, 0.0);
    draw_text(img, font, text, cx - w / 2.0, y, size, 0.0, Rgb([255, 255, 255]), 0.38);
}

/// A knurled aluminium knob: a lit rim, fine marks that fade towards the
/// sides so it reads as round rather than striped, and an inset cap with the
/// concentric marks of a turned face.
fn knob(img: &mut RgbImage, cx: f32, cy: f32, radius: f32) {
    for py in (cy - radius - 2.0) as i32..(cy + radius + 2.0) as i32 {
        for px in (cx - radius - 2.0) as i32..(cx + radius + 2.0) as i32 {
            let (dx, dy) = (px as f32 + 0.5 - cx, py as f32 + 0.5 - cy);
            let distance = (dx * dx + dy * dy).sqrt();
            let inside = (radius - distance + 0.5).clamp(0.0, 1.0);
            if inside <= 0.0 {
                continue;
            }
            // Lit from the upper left, like everything else in the window.
            let t = ((dx / radius) * 0.4 + (dy / radius) * 0.6 + 1.0) / 2.0;
            let shade = 0.34 + (0.09 - 0.34) * t.clamp(0.0, 1.0);
            blend(img, px, py, grey(shade), inside);
        }
    }

    let marks = 56;
    for index in 0..marks {
        let angle = index as f32 / marks as f32 * std::f32::consts::TAU;
        let (sin, cos) = angle.sin_cos();
        let fade = 0.18 + 0.22 * cos.abs();
        let mut r = radius * 0.80;
        while r < radius * 0.995 {
            blend(
                img,
                (cx + cos * r) as i32,
                (cy + sin * r) as i32,
                Rgb([255, 255, 255]),
                fade * 0.5,
            );
            r += 0.45;
        }
    }

    // The flat top, inset, lit from the same corner.
    let cap = radius * 0.735;
    for py in (cy - cap - 2.0) as i32..(cy + cap + 2.0) as i32 {
        for px in (cx - cap - 2.0) as i32..(cx + cap + 2.0) as i32 {
            let (dx, dy) = (px as f32 + 0.5 - cx, py as f32 + 0.5 - cy);
            let distance = (dx * dx + dy * dy).sqrt();
            let inside = (cap - distance + 0.5).clamp(0.0, 1.0);
            if inside <= 0.0 {
                continue;
            }
            let from = ((dx + cap * 0.3).powi(2) + (dy + cap * 0.35).powi(2)).sqrt();
            let t = (from / (cap * 1.6)).clamp(0.0, 1.0);
            blend(img, px, py, grey(0.20 + (0.07 - 0.20) * t), inside);
        }
    }

    let mut ring = cap * 0.86;
    while ring > cap * 0.12 {
        circle_stroke(img, cx, cy, ring, 0.7, Rgb([255, 255, 255]), 0.045);
        ring -= (radius * 2.0 / 26.0).max(2.4);
    }

    // The highlight along the top edge, which is what makes metal read.
    arc_stroke(img, cx, cy, radius * 0.93, 196.0, 318.0, (radius * 2.0 / 60.0).max(1.0), 0.16);
    circle_stroke(img, cx, cy, radius, 1.0, Rgb([0, 0, 0]), 0.55);
}

/// One of the three keys without a display: a rubber dome in a recess.
fn button(img: &mut RgbImage, cx: f32, cy: f32, radius: f32) {
    for py in (cy - radius - 2.0) as i32..(cy + radius + 2.0) as i32 {
        for px in (cx - radius - 2.0) as i32..(cx + radius + 2.0) as i32 {
            let (dx, dy) = (px as f32 + 0.5 - cx, py as f32 + 0.5 - cy);
            let distance = (dx * dx + dy * dy).sqrt();
            let inside = (radius - distance + 0.5).clamp(0.0, 1.0);
            if inside > 0.0 {
                let t = ((dy / radius) + 1.0) / 2.0;
                blend(img, px, py, grey(0.06 + (0.16 - 0.06) * t), inside);
            }
        }
    }

    let dome = radius * 0.80;
    for py in (cy - dome - 2.0) as i32..(cy + dome + 2.0) as i32 {
        for px in (cx - dome - 2.0) as i32..(cx + dome + 2.0) as i32 {
            let (dx, dy) = (px as f32 + 0.5 - cx, py as f32 + 0.5 - cy);
            let distance = (dx * dx + dy * dy).sqrt();
            let inside = (dome - distance + 0.5).clamp(0.0, 1.0);
            if inside <= 0.0 {
                continue;
            }
            let from = ((dx + dome * 0.35).powi(2) + (dy + dome * 0.4).powi(2)).sqrt();
            let t = (from / (dome * 1.7)).clamp(0.0, 1.0);
            blend(img, px, py, grey(0.26 + (0.11 - 0.26) * t), inside);
        }
    }
    circle_stroke(img, cx, cy, radius, 1.0, Rgb([0, 0, 0]), 0.6);
}

// MARK: - Drawing

/// A rectangle with soft corners. The colour is asked for per pixel, with `t`
/// running from nought at the top to one at the bottom, so a gradient needs no
/// second pass.
fn rounded(
    img: &mut RgbImage,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    colour: &dyn Fn(f32, f32) -> (Rgb<u8>, f32),
) {
    for py in y.floor() as i32..(y + h).ceil() as i32 {
        for px in x.floor() as i32..(x + w).ceil() as i32 {
            let (fx, fy) = (px as f32 + 0.5, py as f32 + 0.5);
            if fx < x || fx > x + w || fy < y || fy > y + h {
                continue;
            }
            let dx = (x + radius - fx).max(fx - (x + w - radius)).max(0.0);
            let dy = (y + radius - fy).max(fy - (y + h - radius)).max(0.0);
            let coverage = if dx == 0.0 && dy == 0.0 {
                1.0
            } else {
                (radius - (dx * dx + dy * dy).sqrt() + 0.5).clamp(0.0, 1.0)
            };
            if coverage > 0.0 {
                let (c, a) = colour((fx - x) / w, (fy - y) / h);
                blend(img, px, py, c, coverage * a);
            }
        }
    }
}

/// The bright line along the top edge, fading to nothing by the bottom.
fn rounded_edge(img: &mut RgbImage, x: f32, y: f32, w: f32, h: f32, radius: f32, thickness: f32) {
    for py in y.floor() as i32..(y + h).ceil() as i32 {
        for px in x.floor() as i32..(x + w).ceil() as i32 {
            let (fx, fy) = (px as f32 + 0.5, py as f32 + 0.5);
            let dx = (x + radius - fx).max(fx - (x + w - radius)).max(0.0);
            let dy = (y + radius - fy).max(fy - (y + h - radius)).max(0.0);
            let inside = if dx == 0.0 && dy == 0.0 {
                (fx - x).min(x + w - fx).min(fy - y).min(y + h - fy)
            } else {
                radius - (dx * dx + dy * dy).sqrt()
            };
            let on_edge = (thickness - inside).clamp(0.0, 1.0) * (inside + 0.5).clamp(0.0, 1.0);
            if on_edge > 0.0 {
                let t = ((fy - y) / h).clamp(0.0, 1.0);
                let alpha = (0.22 + (0.03 - 0.22) * (t / 0.5).min(1.0)) * (1.0 - t).max(0.0);
                blend(img, px, py, Rgb([255, 255, 255]), on_edge * alpha.max(0.0));
            }
        }
    }
}

fn circle_stroke(img: &mut RgbImage, cx: f32, cy: f32, r: f32, width: f32, c: Rgb<u8>, a: f32) {
    arc_stroke_coloured(img, cx, cy, r, 0.0, 360.0, width, c, a);
}

fn arc_stroke(img: &mut RgbImage, cx: f32, cy: f32, r: f32, from: f32, to: f32, w: f32, a: f32) {
    arc_stroke_coloured(img, cx, cy, r, from, to, w, Rgb([255, 255, 255]), a);
}

fn arc_stroke_coloured(
    img: &mut RgbImage,
    cx: f32,
    cy: f32,
    r: f32,
    from: f32,
    to: f32,
    width: f32,
    colour: Rgb<u8>,
    alpha: f32,
) {
    let steps = ((to - from).abs() * r / 40.0).max(64.0) as i32;
    for step in 0..=steps {
        let degrees = from + (to - from) * step as f32 / steps as f32;
        let angle = degrees.to_radians();
        let (sin, cos) = angle.sin_cos();
        let mut offset = -width / 2.0;
        while offset <= width / 2.0 {
            blend(
                img,
                (cx + cos * (r + offset)) as i32,
                (cy + sin * (r + offset)) as i32,
                colour,
                alpha,
            );
            offset += 0.5;
        }
    }
}

fn width_of(font: &FontVec, text: &str, size: f32, tracking: f32) -> f32 {
    let scaled = font.as_scaled(PxScale::from(size));
    text.chars()
        .map(|c| scaled.h_advance(scaled.glyph_id(c)) + tracking)
        .sum::<f32>()
        - tracking
}

#[allow(clippy::too_many_arguments)]
fn draw_text(
    img: &mut RgbImage,
    font: &FontVec,
    text: &str,
    x: f32,
    baseline: f32,
    size: f32,
    tracking: f32,
    colour: Rgb<u8>,
    alpha: f32,
) {
    let scale = PxScale::from(size);
    let scaled = font.as_scaled(scale);
    let mut caret = x;
    for ch in text.chars() {
        let id = scaled.glyph_id(ch);
        let glyph = id.with_scale_and_position(scale, ab_glyph::point(caret, baseline));
        caret += scaled.h_advance(id) + tracking;
        if let Some(outline) = font.outline_glyph(glyph) {
            let bounds = outline.px_bounds();
            outline.draw(|gx, gy, coverage| {
                blend(
                    img,
                    bounds.min.x as i32 + gx as i32,
                    bounds.min.y as i32 + gy as i32,
                    colour,
                    coverage * alpha,
                );
            });
        }
    }
}

fn blend(img: &mut RgbImage, x: i32, y: i32, colour: Rgb<u8>, alpha: f32) {
    if x < 0 || y < 0 || x >= img.width() as i32 || y >= img.height() as i32 {
        return;
    }
    let alpha = alpha.clamp(0.0, 1.0);
    let pixel = img.get_pixel_mut(x as u32, y as u32);
    for channel in 0..3 {
        let old = f32::from(pixel[channel]);
        pixel[channel] = (old + (f32::from(colour[channel]) - old) * alpha).round() as u8;
    }
}
