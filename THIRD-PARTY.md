# Third-party components

Pult itself is MIT (see [LICENSE](LICENSE)). It ships, vendors or links the
following, each under its own terms. Two of them ask for attribution in the
product, which is why the About panel names them as well as this file.

## Vendored, and modified

### ajazz-sdk — MPL-2.0

`vendor/ajazz-sdk/` is a fork of the Ajazz/Mirabox device SDK. MPL-2.0 is a
file-level copyleft: the changes to those files stay MPL-2.0 and are listed in
[`vendor/ajazz-sdk/PATCHES.md`](vendor/ajazz-sdk/PATCHES.md), while the rest of
Pult is unaffected and remains MIT.

Two changes were needed and both are recorded there:

* `connect_path`, to open a device by its HID path. One VID/PID/serial exposes
  two interfaces on macOS, and the SDK's own `open_serial` can land on the
  keyboard interface, which macOS refuses to open.
* The AKP03E's key image format is `Rot90`. Without it every key is drawn a
  quarter turn out, which is only obvious once there is hardware in front of
  you.

## Linked

| | | |
|---|---|---|
| [resvg](https://github.com/linebender/resvg) | MPL-2.0 | SVG rendering, for the icon set |
| [image](https://github.com/image-rs/image) | MIT / Apache-2.0 | decoding and encoding |
| [ab_glyph](https://github.com/alexheretic/ab-glyph) | Apache-2.0 | text on keys |
| [hidapi](https://github.com/ruabmbua/hidapi-rs) | MIT | talking to the dock |
| [serde](https://serde.rs), [toml](https://github.com/toml-rs/toml), [anyhow](https://github.com/dtolnay/anyhow) | MIT / Apache-2.0 | configuration and errors |

## Bundled assets

### Lucide — ISC

1865 icons, compiled into the binary rather than shipped as files, so a key's
art survives the app being moved. <https://lucide.dev>

### Inter — SIL Open Font License 1.1

The interface typeface, in `app/Sources/Pult/Resources/Fonts/`. Chosen for full
Latin Extended coverage: Serbian Latin needs č, ć, š, ž and đ, and a typeface
that silently substitutes for them looks broken in half the interface.
<https://rsms.me/inter/>

## Not used, but worth naming

The settings layout follows the shape used by
[PS5Upload](https://github.com/phantomptr/ps5upload) — full-width rows with the
control on the right — and its colour and radius values were measured as a
starting point. No code or asset was copied, and individual measurements are
not an expressive work, so its GPL-3.0 does not reach Pult. It is named here
because the resemblance is deliberate and crediting the idea costs nothing.
