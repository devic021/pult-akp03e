//! A contact sheet of every effect, with the dock's real plastic between the
//! keys, so a motion can be judged without the dock in front of you.
//!
//!   sheet [out.png] [frames]
//!
//! One row per effect, a few frames along it, and the sixteen pixels of bezel
//! drawn in as bezel. That last part is the whole point: on a flat 212x136
//! image every one of these looks fine. The question is what survives being
//! cut into six.

use std::path::PathBuf;

use anyhow::Result;
use image::{Rgb, RgbImage};
use pult::canvas::{self, Canvas, Effect};
use pult::config::Surface;

/// The plastic. Not black: the seam has to be visible as a seam, or the sheet
/// is as misleading as the flat image it replaces.
const BEZEL: Rgb<u8> = Rgb([30, 30, 33]);
const PAPER: Rgb<u8> = Rgb([12, 12, 14]);
const GAP: u32 = 8;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let out = PathBuf::from(args.next().unwrap_or_else(|| "effects.png".to_string()));
    let frames: u32 = args.next().and_then(|n| n.parse().ok()).unwrap_or(6);

    // The dock's own proportions, as the daemon would build them.
    let (cols, rows, key) = (3u32, 2u32, 60u32);
    let pitch = 76;
    let tile_w = cols * pitch - (pitch - key);
    let tile_h = rows * pitch - (pitch - key);

    let effects = Effect::all();
    let width = frames * tile_w + (frames - 1) * GAP;
    let height = effects.len() as u32 * tile_h + (effects.len() as u32 - 1) * GAP;
    let mut sheet = RgbImage::from_pixel(width, height, PAPER);

    for (row, effect) in effects.iter().enumerate() {
        let surface = Surface {
            effect: Some(*effect),
            ..Default::default()
        };
        // Always the effect's own geometry and its own axis: this sheet is for
        // judging the catalogue, not a configuration.
        let mut canvas = Canvas::new(effect.mapping(), cols, rows, key);
        // A whole period across the row, so the frames are a loop and not six
        // samples of the same instant.
        let step = effect.period().min(4.0) / frames as f32;
        let y0 = row as u32 * (tile_h + GAP);

        for frame in 0..frames {
            let tau = frame as f32 * step;
            let style = surface.style(tau, *effect)?;
            canvas::draw(*effect, &mut canvas, tau, &style);
            let x0 = frame * (tile_w + GAP);

            // Lay the bezel down first, then the six keys on top of it, which
            // is the right way round: what falls in a gap is simply not sent.
            for y in 0..tile_h {
                for x in 0..tile_w {
                    sheet.put_pixel(x0 + x, y0 + y, BEZEL);
                }
            }
            for index in 0..canvas.keys() {
                let tile = canvas.tile(index);
                let (ox, oy) = ((index % cols) * pitch, (index / cols) * pitch);
                for y in 0..key {
                    for x in 0..key {
                        sheet.put_pixel(x0 + ox + x, y0 + oy + y, *tile.get_pixel(x, y));
                    }
                }
            }
        }

        println!(
            "row {:>2}  {:<9} {:?} {} fps, period {:.2}s, {} knobs",
            row + 1,
            effect.title(),
            effect.mapping(),
            effect.fps(),
            effect.period(),
            effect.knobs().len(),
        );
    }

    sheet.save(&out)?;
    println!("\n{} ({}x{})", out.display(), width, height);
    Ok(())
}
