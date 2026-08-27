# LayerBar

A tiny macOS menu bar app that shows the **currently active layer** of a ZMK keyboard, e.g. `⌨ Colemak Mod-DH` / `⌨ Nav` / `⌨ QWERTY`.

The keyboard is the source of truth: firmware reports every layer change over a dedicated raw HID interface, so the indicator never drifts out of sync — momentary layers, toggles, replugs and reboots are all reflected correctly.

## How it works

```
ZMK firmware ──(raw HID report)──▶ LayerBar ──▶ NSStatusItem (menu bar)
```

- The firmware side uses the [zmk-feature-appcompanion](https://github.com/Ephemera/zmk-feature-appcompanion) module, which exposes a second USB HID interface (vendor usage page `0xFF60`, usage `0x61`) and sends a 32-byte report on every layer change: byte 24 is a `0x90` marker, byte 25 is the active layer index.
- LayerBar matches only that vendor interface via `IOHIDManager` — it never touches the regular keyboard interface, so no Input Monitoring permission is required.

## Firmware setup

ZMK itself has no built-in way to report the active layer to the host. That part is provided by the
[zmk-feature-appcompanion](https://github.com/Ephemera/zmk-feature-appcompanion) module
(a fork of [maatthc/zmk-feature-appcompanion](https://github.com/maatthc/zmk-feature-appcompanion)
with a CMake fix so it builds as an external `ZMK_EXTRA_MODULES` module).

### 1. Add the module to the build

With a [miryoku_zmk](https://github.com/manna-harbour/miryoku_zmk)-style workflow, pass it via the `modules` input:

```yaml
jobs:
  build:
    uses: ./.github/workflows/main.yml
    secrets: inherit
    with:
      board: '["planck//zmk"]'
      modules: '["Ephemera/zmk-feature-appcompanion/main"]'
```

With a plain zmk-config, add it to `config/west.yml` instead:

```yaml
manifest:
  remotes:
    - name: ephemera
      url-base: https://github.com/Ephemera
  projects:
    - name: zmk-feature-appcompanion
      remote: ephemera
      revision: main
```

### 2. Enable it in your keyboard `.conf`

```ini
# a second USB HID interface for the raw reports (HID_0 is the keyboard itself)
CONFIG_USB_HID_DEVICE_COUNT=2
CONFIG_ZMK_LAYER_STATUS_USB_HID=y
```

The vendor usage page/usage default to `0xFF60`/`0x61` and can be overridden with
`CONFIG_ZMK_LAYER_STATUS_USB_HID_USAGE_PAGE` / `CONFIG_ZMK_LAYER_STATUS_USB_HID_USAGE`
(update the app config to match).

### Report protocol

On every layer state change the firmware sends one 32-byte input report on the vendor interface:

| bytes | content |
|---|---|
| 0–23 | `0x00` |
| 24 | `0x90` marker |
| 25 | active layer index (highest active layer) |
| 26–31 | `0x00` |

Notes: USB only (the module's BLE variant embeds the layer into the keyboard report instead, which LayerBar does not read). On a split keyboard the module must run on the central side.

## Build & install

```sh
./make-app.sh
```

Builds a release binary and installs `LayerBar.app` into `~/Applications` (ad-hoc signed). Add it to **System Settings → General → Login Items** to start it at login.

## Configuration

`~/.config/layerbar/config.json` is created on first launch:

```json
{
    "vendorId": "0x1D50",
    "productId": "0x615E",
    "usagePage": "0xFF60",
    "usage": "0x61",
    "prefix": "⌨ ",
    "disconnectedText": "–",
    "layers": ["Base", "QWERTY", "Tap", "Button", "Nav", "Mouse", "Media", "Num", "Sym", "Fun"]
}
```

- `layers` — display names by layer index (rename freely, e.g. `"Colemak Mod-DH"`)
- `prefix` / `disconnectedText` — menu bar text decoration
- `vendorId` / `productId` / `usagePage` / `usage` — match a different keyboard without code changes (hex strings or decimal numbers)

Use the menu bar icon's **Open Config** / **Reload Config** items to edit and apply without restarting.

## CI

Pushes to `main` build the app bundle on a macOS runner and upload it as a `LayerBar` artifact (zip). Pushing a `v*` tag (e.g. `v1.0`) additionally publishes the zip as a GitHub Release with auto-generated notes. Downloaded bundles are quarantined by Gatekeeper; clear it with:

```sh
xattr -d com.apple.quarantine LayerBar.app
```
