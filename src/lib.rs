//! Host-side driver for the Ajazz AKP03E stream dock.
//!
//! The device is a screen plus an event source: it holds no state of its own,
//! so every scene lives here and is pushed over HID.

pub mod action;
pub mod animation;
pub mod canvas;
pub mod config;
pub mod control;
pub mod device;
pub mod feed;
pub mod frontmost;
pub mod icons;
pub mod idle;
pub mod permissions;
pub mod power;
pub mod render;
pub mod values;
