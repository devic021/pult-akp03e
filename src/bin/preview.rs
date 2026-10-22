//! Renders a scene to a PNG, so key art can be checked without the dock.
//!
//!   preview <scene>[:page] [out.png] [config.toml]

use std::path::PathBuf;

use pult::config::{self, Config};
use pult::render::{Frame, Renderer};
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
            ..Frame::default()
        };
        let image = renderer.key_frame(spec, frame)?.to_rgb8();
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
