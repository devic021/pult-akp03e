//! Measures how fast the dock accepts key images, which is what decides
//! whether animation is possible and at what frame rate.

use std::time::{Duration, Instant};

use ajazz_sdk::new_hidapi;
use pult::config::Key;
use pult::device;
use pult::render::Renderer;
use anyhow::Result;

const ROUNDS: usize = 20;

fn main() -> Result<()> {
    let hid = new_hidapi()?;
    let (found, dock) = device::open(&hid)?;
    let (w, h) = found.kind.key_image_format().size;
    let renderer = Renderer::new(None, (w as u32, h as u32))?;
    let display_keys = found.kind.display_key_count();

    println!("{:?}, {} keys of {w}x{h}\n", found.kind, display_keys);

    // Render once, outside the timing: we are measuring the wire, not the CPU.
    let frames: Vec<_> = (0..display_keys)
        .map(|i| {
            renderer.key(&Key {
                label: format!("{i}"),
                color: Some("#202020".to_string()),
                ..Key::default()
            })
        })
        .collect::<Result<_>>()?;

    let render = {
        let start = Instant::now();
        for _ in 0..ROUNDS {
            renderer.key(&Key {
                label: "x".to_string(),
                ..Key::default()
            })?;
        }
        start.elapsed() / ROUNDS as u32
    };

    let one = time(ROUNDS, || {
        dock.set_button_image(0, frames[0].clone())?;
        dock.flush()
    })?;

    let all = time(ROUNDS, || {
        for (index, frame) in frames.iter().enumerate() {
            dock.set_button_image(index as u8, frame.clone())?;
        }
        dock.flush()
    })?;

    println!("render one key (cpu) : {:>7.1} ms", ms(render));
    println!("send one key         : {:>7.1} ms  -> {:.0} fps", ms(one), fps(one));
    println!("send all {display_keys} keys       : {:>7.1} ms  -> {:.0} fps", ms(all), fps(all));

    dock.clear_all_button_images()?;
    dock.flush()?;
    Ok(())
}

fn time(rounds: usize, mut step: impl FnMut() -> Result<(), ajazz_sdk::AjazzError>) -> Result<Duration> {
    let start = Instant::now();
    for _ in 0..rounds {
        step()?;
    }
    Ok(start.elapsed() / rounds as u32)
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn fps(d: Duration) -> f64 {
    1.0 / d.as_secs_f64()
}
