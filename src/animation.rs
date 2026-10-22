//! Animations a person brings themselves.
//!
//! Everything here happens once, when a scene is loaded: decode, scale to the
//! canvas, cut into tiles. The loop that drives the dock then only picks an
//! index and hands six ready images to the device — it never decodes, never
//! resizes and never scales, because a 1920x1080 GIF off the internet costs
//! tens of milliseconds a frame and the loop has five.
//!
//! What can be brought, established by decoding real files rather than from
//! memory:
//!
//! | Format                        | Why it works                          |
//! |-------------------------------|---------------------------------------|
//! | APNG                          | `image/png`, already on               |
//! | GIF                           | `image/gif`, no new crates            |
//! | Animated WebP                 | `image/webp`, no new crates           |
//! | A folder of numbered frames   | ordinary PNG or JPEG, timing from fps |
//! | One still picture             | a backdrop; Pult supplies the motion  |
//!
//! Not possible here: MP4 and friends need a video decoder, animated AVIF
//! needs a system libdav1d, and SVG animation is SMIL, which resvg does not
//! implement at any version.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use image::{AnimationDecoder, DynamicImage, RgbImage};

use serde::{Deserialize, Serialize};

use crate::canvas::{Canvas, Mapping};

/// How a picture is made to fit a canvas that is always landscape.
///
/// The dock lies flat and wide: 212x136, about 1.56:1. Most animations on the
/// internet are portrait video clips, and covering the canvas with one throws
/// away two thirds of its height — so the choice is worth making deliberately
/// rather than silently.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fit {
    /// Fill the canvas and crop what hangs over. Right for anything already
    /// wider than it is tall.
    #[default]
    Cover,
    /// Show all of it, with the background either side. Right for a portrait
    /// source you would otherwise lose most of.
    Contain,
    /// Distort it to the canvas. Occasionally what an abstract loop wants.
    Stretch,
}

/// How much of the cropped axis a `cover` must leave before it stops being a
/// crop and starts being vandalism.
///
/// Measured, not chosen: at 212x136 a square source covered keeps 64% of its
/// height, and that still reads — an emoji or a logo carries a wide empty
/// margin and cover eats the margin. A phone video keeps 36% and reads as a
/// mistake. Sixty per cent sits between them.
const KEEP: f32 = 0.60;

/// What `cover` would leave of a source, and the fit that fraction argues for.
///
/// `aspect` is the source's width over its height *after* any rotation,
/// `target` the canvas's. The threshold is symmetric on purpose: a banner four
/// times wider than it is tall loses as much of itself to a cover as a phone
/// video does, and the rule this replaces was one constant checked only
/// against portrait sources — so a source at 0.90 was cropped to 58% of its
/// height without a word being said about it.
pub fn suggest(aspect: f32, target: f32) -> (Fit, f32) {
    let kept = if aspect >= target {
        target / aspect
    } else {
        aspect / target
    };
    let fit = if kept >= KEEP { Fit::Cover } else { Fit::Contain };
    (fit, kept)
}

/// Beyond this an animation is a video, and the memory it would take is not
/// worth a key pad. At 212x136 a frame is about 86 KB of tiles, so this caps
/// one animation at roughly 50 MB.
const MAX_FRAMES: usize = 600;

/// What to do when a source carries no timing of its own.
const DEFAULT_FPS: u8 = 15;

pub struct Frame {
    /// One image per key, already the size the device wants.
    pub tiles: Vec<RgbImage>,
    /// How long this frame is held.
    pub delay: Duration,
}

pub struct Animation {
    frames: Vec<Frame>,
    /// The sum of every delay, so a time can be wrapped without walking.
    total: Duration,
}

impl Animation {
    pub fn frames(&self) -> usize {
        self.frames.len()
    }

    pub fn duration(&self) -> Duration {
        self.total
    }

    /// The frame showing at `time` seconds, looping.
    pub fn at(&self, time: f32) -> &Frame {
        if self.frames.len() == 1 || self.total.is_zero() {
            return &self.frames[0];
        }

        let mut remaining = Duration::from_secs_f32(time.max(0.0).rem_euclid(
            self.total.as_secs_f32(),
        ));
        for frame in &self.frames {
            if remaining < frame.delay {
                return frame;
            }
            remaining -= frame.delay;
        }
        // Floating point can land a hair past the end.
        self.frames.last().expect("an animation has frames")
    }

    /// Reads a file or a folder of frames and prepares it for one dock.
    #[allow(clippy::too_many_arguments)]
    pub fn load(
        path: &Path,
        mapping: Mapping,
        cols: u32,
        rows: u32,
        key: u32,
        fps: Option<u8>,
        fit: Fit,
        rotate: u16,
        background: image::Rgb<u8>,
    ) -> Result<Animation> {
        let pictures = if path.is_dir() {
            read_folder(path)?
        } else {
            read_file(path)?
        };

        if pictures.is_empty() {
            bail!("{} holds no frames", path.display());
        }

        // Integer nanoseconds, not a float division: a tenth of a second
        // through f32 is 100.000001 ms, and the error accumulates over a loop.
        let rate = u64::from(fps.unwrap_or(DEFAULT_FPS).max(1));
        let fallback = Duration::from_nanos(1_000_000_000 / rate);
        let mut canvas = Canvas::new(mapping, cols, rows, key);
        let keys = canvas.keys();

        let mut frames = Vec::with_capacity(pictures.len());
        let mut total = Duration::ZERO;

        // Said once, not once per frame: an animation of the wrong shape
        // covered onto a landscape dock loses most of itself, and silently is
        // the wrong way to do that.
        if let Some((first, _)) = pictures.first() {
            // After the rotation, because a clip filmed sideways is landscape
            // by the time it reaches the canvas.
            let (w, h) = if rotate % 180 == 90 {
                (first.height(), first.width())
            } else {
                (first.width(), first.height())
            };
            let aspect = w as f32 / h.max(1) as f32;
            let target = canvas.width() as f32 / canvas.height() as f32;
            let (wanted, kept) = suggest(aspect, target);
            if fit == Fit::Cover && wanted == Fit::Contain {
                let axis = if aspect >= target { "width" } else { "height" };
                eprintln!(
                    "{} is {}x{}: covering it on a {}x{} dock keeps about {:.0}% of its {axis}. \
                     Try fit = \"contain\", or rotate = 90 if it was filmed sideways.",
                    path.display(),
                    first.width(),
                    first.height(),
                    canvas.width(),
                    canvas.height(),
                    100.0 * kept,
                );
            }
        }

        for (image, delay) in pictures {
            let scaled = fit_into(image, canvas.width(), canvas.height(), fit, rotate, background);
            canvas.image_mut().copy_from_slice(&scaled);

            let delay = delay.filter(|d| !d.is_zero()).unwrap_or(fallback);
            total += delay;
            frames.push(Frame {
                tiles: (0..keys).map(|index| canvas.tile(index)).collect(),
                delay,
            });
        }

        Ok(Animation { frames, total })
    }
}

/// Turns any picture into exactly the canvas's size, the way `fit` asks.
fn fit_into(
    image: DynamicImage,
    width: u32,
    height: u32,
    fit: Fit,
    rotate: u16,
    background: image::Rgb<u8>,
) -> RgbImage {
    // Rotation first: a clip filmed sideways should be straightened before
    // anything decides what to crop.
    let image = match rotate % 360 {
        90 => image.rotate90(),
        180 => image.rotate180(),
        270 => image.rotate270(),
        _ => image,
    };

    match fit {
        Fit::Cover => image
            .resize_to_fill(width, height, image::imageops::FilterType::Triangle)
            .to_rgb8(),

        Fit::Stretch => image
            .resize_exact(width, height, image::imageops::FilterType::Triangle)
            .to_rgb8(),

        Fit::Contain => {
            let inner = image
                .resize(width, height, image::imageops::FilterType::Triangle)
                .to_rgb8();
            let mut canvas = RgbImage::from_pixel(width, height, background);
            let x = (width - inner.width()) / 2;
            let y = (height - inner.height()) / 2;
            image::imageops::replace(&mut canvas, &inner, x.into(), y.into());
            canvas
        }
    }
}

/// Decodes one file, animated or not.
fn read_file(path: &Path) -> Result<Vec<(DynamicImage, Option<Duration>)>> {
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let open = || -> Result<BufReader<File>> {
        Ok(BufReader::new(
            File::open(path).with_context(|| format!("opening {}", path.display()))?,
        ))
    };

    match extension.as_str() {
        "gif" => {
            let decoder = image::codecs::gif::GifDecoder::new(open()?)
                .with_context(|| format!("reading {} as GIF", path.display()))?;
            collect(decoder.into_frames())
        }

        "png" | "apng" => {
            let decoder = image::codecs::png::PngDecoder::new(open()?)
                .with_context(|| format!("reading {} as PNG", path.display()))?;
            if decoder.is_apng()? {
                collect(decoder.apng()?.into_frames())
            } else {
                Ok(vec![(image::open(path)?, None)])
            }
        }

        "webp" => {
            let decoder = image::codecs::webp::WebPDecoder::new(open()?)
                .with_context(|| format!("reading {} as WebP", path.display()))?;
            if decoder.has_animation() {
                collect(decoder.into_frames())
            } else {
                Ok(vec![(image::open(path)?, None)])
            }
        }

        // Anything else the image crate can read is one still picture, which
        // is a perfectly good backdrop.
        _ => Ok(vec![(
            image::open(path).with_context(|| format!("reading {}", path.display()))?,
            None,
        )]),
    }
}

/// Reads a folder of numbered frames, in name order.
///
/// The most robust thing a person can hand us: no container, no codec
/// surprises, and one frame can be re-exported without redoing the rest.
fn read_folder(path: &Path) -> Result<Vec<(DynamicImage, Option<Duration>)>> {
    let mut files: Vec<_> = std::fs::read_dir(path)
        .with_context(|| format!("reading {}", path.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|file| {
            matches!(
                file.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref(),
                Some("png" | "jpg" | "jpeg")
            )
        })
        .collect();

    // Sorted by name, which is why the frames want numbering.
    files.sort();
    if files.len() > MAX_FRAMES {
        bail!(
            "{} holds {} frames; the limit is {MAX_FRAMES}",
            path.display(),
            files.len()
        );
    }

    files
        .iter()
        .map(|file| {
            let image = image::open(file)
                .with_context(|| format!("reading {}", file.display()))?;
            // A folder carries no timing, so every frame takes the configured
            // rate — one knob instead of a thousand.
            Ok((image, None))
        })
        .collect()
}

/// Turns a decoder's frames into pictures and delays.
fn collect(frames: image::Frames<'_>) -> Result<Vec<(DynamicImage, Option<Duration>)>> {
    let frames = frames
        .take(MAX_FRAMES + 1)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|e| anyhow!("decoding frames: {e}"))?;

    if frames.len() > MAX_FRAMES {
        bail!("more than {MAX_FRAMES} frames; this is a video, not a key animation");
    }

    Ok(frames
        .into_iter()
        .map(|frame| {
            let (numerator, denominator) = frame.delay().numer_denom_ms();
            let delay = (denominator > 0)
                .then(|| Duration::from_secs_f64(f64::from(numerator) / f64::from(denominator) / 1000.0));
            (DynamicImage::ImageRgba8(frame.into_buffer()), delay)
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The numbers in the fitting rule, written down where a change to the
    /// constant has to argue with them.
    #[test]
    fn the_fit_follows_what_a_crop_would_cost() {
        let dock = 212.0 / 136.0;

        // 16:9 and the GOES satellite loops: a cover barely touches them.
        assert_eq!(suggest(1920.0 / 1080.0, dock).0, Fit::Cover);
        assert_eq!(suggest(625.0 / 375.0, dock).0, Fit::Cover);

        // A square keeps 64% of its height, and an emoji's margin is what goes.
        let (fit, kept) = suggest(1.0, dock);
        assert_eq!(fit, Fit::Cover);
        assert!((kept - 0.642).abs() < 0.01, "a square keeps {kept}");

        // A phone video keeps 36%, which is a different video.
        let (fit, kept) = suggest(1080.0 / 1920.0, dock);
        assert_eq!(fit, Fit::Contain);
        assert!((kept - 0.361).abs() < 0.01, "a phone video keeps {kept}");

        // Symmetric: a wide banner is refused a cover for the same reason.
        assert_eq!(suggest(1134.0 / 280.0, dock).0, Fit::Contain);

        // The old constant said 1.15 (an aspect of 0.870) and let this one
        // through silently at 58% of its height.
        assert_eq!(suggest(0.90, dock).0, Fit::Contain);
    }
    use image::{Rgba, RgbaImage};

    /// Writes a three-frame animated GIF to a temporary path.
    fn write_gif(path: &Path) {
        let mut file = File::create(path).expect("create gif");
        let mut encoder = image::codecs::gif::GifEncoder::new(&mut file);
        encoder.set_repeat(image::codecs::gif::Repeat::Infinite).ok();

        for shade in [40u8, 140, 240] {
            let mut frame = RgbaImage::new(64, 64);
            for pixel in frame.pixels_mut() {
                *pixel = Rgba([shade, shade / 2, 255 - shade, 255]);
            }
            encoder
                .encode_frame(image::Frame::from_parts(
                    frame,
                    0,
                    0,
                    image::Delay::from_numer_denom_ms(100, 1),
                ))
                .expect("encode frame");
        }
    }

    #[test]
    fn a_gif_becomes_tiles_for_every_key() {
        let path = std::env::temp_dir().join("pult-test-animation.gif");
        write_gif(&path);

        let animation = Animation::load(
            &path,
            Mapping::Packed,
            3,
            2,
            60,
            None,
            Fit::Cover,
            0,
            image::Rgb([0, 0, 0]),
        )
        .expect("the gif loads");

        assert_eq!(animation.frames(), 3);
        // 100 ms a frame, as encoded.
        assert_eq!(animation.duration(), Duration::from_millis(300));

        let frame = animation.at(0.0);
        assert_eq!(frame.tiles.len(), 6);
        assert_eq!(frame.tiles[0].width(), 60);
        assert_eq!(frame.tiles[0].height(), 60);

        // Each frame is a different shade, so time picks different pictures.
        let first = animation.at(0.01).tiles[0].get_pixel(10, 10)[0];
        let third = animation.at(0.25).tiles[0].get_pixel(10, 10)[0];
        assert_ne!(first, third, "time did not advance the animation");

        // And it loops rather than running off the end.
        assert_eq!(
            animation.at(0.31).tiles[0].get_pixel(10, 10)[0],
            animation.at(0.01).tiles[0].get_pixel(10, 10)[0]
        );

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_still_picture_is_an_animation_of_one_frame() {
        let path = std::env::temp_dir().join("pult-test-still.png");
        let mut picture = RgbaImage::new(40, 40);
        for pixel in picture.pixels_mut() {
            *pixel = Rgba([10, 200, 90, 255]);
        }
        picture.save(&path).expect("save png");

        let animation = Animation::load(
            &path,
            Mapping::Physical,
            3,
            2,
            60,
            Some(15),
            Fit::Cover,
            0,
            image::Rgb([0, 0, 0]),
        )
        .expect("the picture loads");
        assert_eq!(animation.frames(), 1);
        assert_eq!(animation.at(99.0).tiles.len(), 6);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_portrait_source_can_keep_all_of_itself() {
        let path = std::env::temp_dir().join("pult-test-portrait.png");
        // Tall and narrow, with a bright band only near the top.
        let mut picture = RgbaImage::new(60, 200);
        for (_, y, pixel) in picture.enumerate_pixels_mut() {
            *pixel = if y < 20 {
                Rgba([255, 255, 255, 255])
            } else {
                Rgba([0, 0, 0, 255])
            };
        }
        picture.save(&path).expect("save png");

        let black = image::Rgb([0, 0, 0]);
        let covered =
            Animation::load(&path, Mapping::Packed, 3, 2, 60, Some(15), Fit::Cover, 0, black)
                .expect("cover loads");
        let contained =
            Animation::load(&path, Mapping::Packed, 3, 2, 60, Some(15), Fit::Contain, 0, black)
                .expect("contain loads");

        // Covering a 60x200 source onto 180x120 crops the band away entirely;
        // containing it keeps it.
        let lit = |a: &Animation| {
            a.at(0.0)
                .tiles
                .iter()
                .map(|t| t.pixels().filter(|p| p[0] > 200).count())
                .sum::<usize>()
        };
        assert_eq!(lit(&covered), 0, "cover was expected to crop the band away");
        assert!(lit(&contained) > 0, "contain lost the band it was meant to keep");

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_folder_of_frames_is_read_in_name_order() {
        let folder = std::env::temp_dir().join("pult-test-frames");
        std::fs::create_dir_all(&folder).expect("make folder");

        for (index, shade) in [20u8, 120, 220].into_iter().enumerate() {
            let mut picture = RgbaImage::new(32, 32);
            for pixel in picture.pixels_mut() {
                *pixel = Rgba([shade, shade, shade, 255]);
            }
            picture
                .save(folder.join(format!("{:03}.png", index + 1)))
                .expect("save frame");
        }

        let animation = Animation::load(
            &folder,
            Mapping::Packed,
            3,
            2,
            60,
            Some(10),
            Fit::Cover,
            0,
            image::Rgb([0, 0, 0]),
        )
        .expect("the folder loads");

        assert_eq!(animation.frames(), 3);
        // No timing in the files, so the configured rate decides.
        assert_eq!(animation.duration(), Duration::from_millis(300));
        assert!(animation.at(0.0).tiles[0].get_pixel(1, 1)[0] < 60);

        std::fs::remove_dir_all(&folder).ok();
    }
}
