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

Add the module to your ZMK build and enable it in your keyboard `.conf`:

```ini
CONFIG_USB_HID_DEVICE_COUNT=2
CONFIG_ZMK_LAYER_STATUS_USB_HID=y
```

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
