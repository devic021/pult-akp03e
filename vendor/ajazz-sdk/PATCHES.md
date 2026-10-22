# Local changes to ajazz-sdk 0.2.1

Upstream: https://github.com/mishamyrt/ajazz-sdk (MPL-2.0)

## `src/device.rs` — added `Ajazz::connect_path`

Upstream only connects by VID/PID/serial (`hidapi.open_serial`). The AKP03E
exposes two HID interfaces under one VID/PID/serial:

    iface 0  usage_page 0xFFA0  vendor pipe (images + input)   opens fine
    iface 1  usage_page 0x0001  boot keyboard                  macOS refuses
                                                               without Input
                                                               Monitoring

`hid_open()` takes the first match from a fresh enumeration, whose order is not
guaranteed, so `connect()` lands on the keyboard interface and fails with
`(0xE00002C1) privilege violation`. `connect_path` takes the path we picked
ourselves, so we can always open the vendor pipe.

Everything else is upstream 0.2.1 verbatim. Nothing was removed; `connect` and
`connect_with_retries` still behave as before.

## `src/info.rs` — `Akp03E` key images are rotated

Upstream gives the whole AKP03 family `ImageRotation::Rot0`. On the AKP03E the
panel is mounted turned a quarter, so an unrotated image shows up on the key
reading bottom to top, with the tops of the letters facing left. Photographed
and confirmed on hardware (`0300:3002`, firmware `V3.AKP03E_PXL.02.010`).

`Akp03E` now uses `Rot90`; `Akp03` and `Akp03R` keep upstream's `Rot0`, since
only the AKP03E was here to test. Upstream already gives the AKP03R rev 2
`Rot90`, so this is the same quirk on a neighbouring model.
