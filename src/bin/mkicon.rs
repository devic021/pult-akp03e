//! Draws the application icon at every size macOS asks for.
//!
//!   mkicon <out-dir>
//!
//! The mark is the dock itself seen from above: six keys, one of them lit,
//! which is exactly what the program does.

use std::path::PathBuf;

use anyhow::{Context, Result};
use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg;

/// Sizes an .iconset needs, as (pixels, file name).
const SIZES: &[(u32, &str)] = &[
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
];

fn mark() -> String {
    // Apple's macOS icon geometry: the artwork sits in an 824 pt rounded square
    // centred on a 1024 canvas, leaving the margin the system expects. Drawing
    // edge to edge is what makes a hand-made icon look wrong next to the rest
    // of the Dock.
    const INSET: f32 = 100.0;
    const BOX: f32 = 824.0;
    const RADIUS: f32 = 185.0;

    // Six keys, 2x3, filling the middle of the square. Generous corners, wide
    // gaps: the shape has to survive being 16 px wide.
    const KEY: f32 = 188.0;
    const GAP: f32 = 26.0;
    const KEY_RADIUS: f32 = 48.0;

    let grid_width = 3.0 * KEY + 2.0 * GAP;
    let grid_height = 2.0 * KEY + GAP;
    let origin_x = 512.0 - grid_width / 2.0;
    let origin_y = 512.0 - grid_height / 2.0;

    let mut keys = String::new();
    for row in 0..2 {
        for col in 0..3 {
            let x = origin_x + col as f32 * (KEY + GAP);
            let y = origin_y + row as f32 * (KEY + GAP);
            // One key is lit, the way one scene is always the active one.
            let lit = row == 0 && col == 1;
            if lit {
                // The glow is what says "live" rather than "another grid of
                // squares"; a radial gradient rather than a blur filter, which
                // not every renderer handles the same way.
                let cx = x + KEY / 2.0;
                let cy = y + KEY / 2.0;
                keys.push_str(&format!(
                    r#"<circle cx="{cx:.1}" cy="{cy:.1}" r="210" fill="url(#glow)"/>"#
                ));
            }
            let fill = if lit { "#ffffff" } else { "rgba(255,255,255,0.24)" };
            keys.push_str(&format!(
                r#"<rect x="{x:.1}" y="{y:.1}" width="{KEY}" height="{KEY}" rx="{KEY_RADIUS}" fill="{fill}"/>"#
            ));
        }
    }

    format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="face" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop offset="0" stop-color="#5b6cff"/>
      <stop offset="0.52" stop-color="#3b49d6"/>
      <stop offset="1" stop-color="#1b2060"/>
    </linearGradient>
    <radialGradient id="glow">
      <stop offset="0" stop-color="#cfe0ff" stop-opacity="0.55"/>
      <stop offset="0.45" stop-color="#9fb8ff" stop-opacity="0.18"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.30"/>
      <stop offset="0.55" stop-color="#ffffff" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="face-clip">
      <rect x="{INSET}" y="{INSET}" width="{BOX}" height="{BOX}" rx="{RADIUS}"/>
    </clipPath>
  </defs>

  <rect x="{INSET}" y="{INSET}" width="{BOX}" height="{BOX}" rx="{RADIUS}" fill="url(#face)"/>

  <g clip-path="url(#face-clip)">
    <!-- A light falling across the top, which is what makes glass read as glass. -->
    <ellipse cx="420" cy="140" rx="700" ry="430" fill="url(#sheen)"/>
  </g>

  <g clip-path="url(#face-clip)">
    {keys}
  </g>

  <rect x="{INSET}" y="{INSET}" width="{BOX}" height="{BOX}" rx="{RADIUS}"
        fill="none" stroke="#ffffff" stroke-opacity="0.18" stroke-width="3"/>
</svg>"##
    )
}

fn main() -> Result<()> {
    let out: PathBuf = std::env::args()
        .nth(1)
        .context("usage: mkicon <out-dir>")?
        .into();
    std::fs::create_dir_all(&out)?;

    let svg = mark();
    let tree = usvg::Tree::from_str(&svg, &usvg::Options::default()).context("parsing icon")?;

    for (size, name) in SIZES {
        let mut pixmap = Pixmap::new(*size, *size).context("allocating pixmap")?;
        let scale = *size as f32 / tree.size().width();
        resvg::render(
            &tree,
            Transform::from_scale(scale, scale),
            &mut pixmap.as_mut(),
        );
        pixmap
            .save_png(out.join(name))
            .with_context(|| format!("writing {name}"))?;
    }

    println!("wrote {} sizes to {}", SIZES.len(), out.display());
    Ok(())
}
