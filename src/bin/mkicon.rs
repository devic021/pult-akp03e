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
    let mut keys = String::new();
    for row in 0..2 {
        for col in 0..3 {
            let x = 168 + col * 232;
            let y = 268 + row * 232;
            // One key carries the accent, the way one scene is always active.
            let fill = if row == 0 && col == 1 { "#4c8dff" } else { "#2f3540" };
            keys.push_str(&format!(
                r#"<rect x="{x}" y="{y}" width="184" height="184" rx="44" fill="{fill}"/>"#
            ));
        }
    }

    format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#20242c"/>
      <stop offset="1" stop-color="#121419"/>
    </linearGradient>
  </defs>
  <rect x="64" y="64" width="896" height="896" rx="200" fill="url(#body)"/>
  <rect x="64" y="64" width="896" height="896" rx="200" fill="none"
        stroke="#3a4150" stroke-width="8"/>
  {keys}
  <circle cx="760" cy="384" r="104" fill="#2f3540" stroke="#4a5262" stroke-width="10"/>
  <circle cx="760" cy="384" r="34" fill="#4a5262"/>
  <circle cx="704" cy="640" r="52" fill="#2f3540" stroke="#4a5262" stroke-width="8"/>
  <circle cx="824" cy="640" r="52" fill="#2f3540" stroke="#4a5262" stroke-width="8"/>
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
