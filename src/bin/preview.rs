//! Renders a scene to a PNG, so key art can be checked without the dock.
//!
//!   preview <scene>[:page] [out.png] [config.toml]
//!
//! A scene that reads from feeds is polled once, here, before anything is
//! drawn: a page of readings is only worth looking at with real numbers on it.
//! `PULT_HOUR=3` draws it as the forecast three hours out, the way the big
//! knob would.

use std::path::PathBuf;
use std::time::SystemTime;

use pult::config::{self, Config};
use pult::feed;
use pult::render::{Frame, Renderer};
use pult::values::Bindings;
use anyhow::{Context, Result};
use image::{Rgb, RgbImage};

/// Scale factor: 60x60 keys are too small to judge on a desktop display.
const ZOOM: u32 = 4;
const GAP: u32 = 8;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let wanted = args.next().unwrap_or_else(|| "general".to_string());
    let (scene_name, page) = match wanted.split_once(':') {
        Some((name, page)) => (name.to_string(), page.parse::<usize>()?.saturating_sub(1)),
        None => (wanted, 0),
    };
    let out = PathBuf::from(args.next().unwrap_or_else(|| "preview.png".to_string()));
    let config_path = config::resolve_path(args.next().as_deref())?;

    let config = Config::load(&config_path)?;
    let renderer = Renderer::new(config.font.as_deref(), (60, 60))?;
    let scene = config
        .scene(&scene_name)
        .with_context(|| format!("no scene named {scene_name:?}"))?;

    // Polled on this thread and once only: there is no loop here to wait for
    // a poller, and a preview that drew em dashes would be a preview of
    // nothing.
    let mut bindings = Bindings::new();
    let places = feed::places();
    for (name, spec) in &config.feeds {
        bindings.declare(name, spec.stale_after());
        let polled = spec
            .target(&places)
            .and_then(|target| feed::poll(spec, &target, SystemTime::now()));
        match polled {
            Ok(sample) => {
                println!("feed    : {name} gave {} fields", sample.fields.len());
                bindings.put(name, sample);
            }
            Err(e) => {
                eprintln!("feed    : {name} did not answer: {e:#}");
                bindings.fail(name, format!("{e:#}"));
            }
        }
    }

    let hours: i32 = std::env::var("PULT_HOUR")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let now = SystemTime::now();

    let (rows, cols) = (2u32, 3u32);
    let per_page = (rows * cols) as usize;
    let pages = scene.pages(per_page);
    let keys = scene.page(page, per_page);
    let marker = (pages > 1).then_some((page, pages));
    let key = 60 * ZOOM;
    let mut sheet = RgbImage::from_pixel(
        cols * key + (cols + 1) * GAP,
        rows * key + (rows + 1) * GAP,
        Rgb([60, 60, 60]),
    );

    for index in 0..rows * cols {
        let Some(spec) = keys.get(index as usize) else {
            continue;
        };
        let frame = Frame {
            pages: marker,
            hour: (hours != 0).then_some((hours.unsigned_abs() as usize, 24)),
            ..Frame::default()
        };
        let image = renderer
            .reading(spec, &bindings, now, hours, frame)?
            .to_rgb8();
        let (row, col) = (index / cols, index % cols);
        let (ox, oy) = (
            GAP + col * (key + GAP),
            GAP + row * (key + GAP),
        );

        for (x, y, px) in image.enumerate_pixels() {
            for dy in 0..ZOOM {
                for dx in 0..ZOOM {
                    sheet.put_pixel(ox + x * ZOOM + dx, oy + y * ZOOM + dy, *px);
                }
            }
        }
    }

    sheet.save(&out).with_context(|| format!("writing {}", out.display()))?;
    println!(
        "wrote {} for scene {scene_name:?}, page {} of {pages}",
        out.display(),
        page + 1
    );
    Ok(())
}
