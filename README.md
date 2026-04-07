# portrait-display

Turn a USB display into a portrait (vertical) monitor on macOS — even when the OS won't let you rotate it.

## Why This Exists

Apple Silicon MacBook Air (M1/M2/M3) only supports **one** external display natively. USB display adapters like j5create or DisplayLink can add more screens by creating virtual framebuffers, but macOS **cannot rotate** these virtual displays:

- `displayplacer degree:90` → timeout after 10s
- System Settings → rotation option doesn't exist for USB displays
- `CGConfigureDisplayMirrorOfDisplay` → error 1001 (resolution mismatch)

This tool works around the limitation with a software-based rotation pipeline.

## Hardware Requirements

### USB Display Adapter

You need a **USB-C to Dual HDMI adapter** that uses one of these chipsets:

| Chipset | Example Products | Notes |
|---------|-----------------|-------|
| **MCT T6** (Magic Control Technology) | j5create JCA365, JCA366 | Tested. Uses j5create's own driver |
| **DisplayLink** | Plugable, StarTech, Dell | Should also work (same virtual framebuffer architecture) |

**How to identify the chipset** before buying:
- Check the product page for "driver required" — if yes, it's likely MCT or DisplayLink
- MCT products: look for j5create brand, Vendor ID `0x0711`
- DisplayLink products: usually mention "DisplayLink" explicitly

> **Thunderbolt docks** (CalDigit, OWC, etc.) use native DisplayPort alt-mode and DO support rotation — you don't need this tool for those. This tool is specifically for **USB virtual display** adapters.

### Monitors

Any monitor works. The tool defaults to targeting 1920x1080 displays for portrait mode, but you can specify any display ID.

### Tested Setup

| Device | Model | Resolution |
|--------|-------|------------|
| Laptop | MacBook Air M3 (8GB) | 2560x1664 Retina |
| Adapter | j5create USB-C to Dual HDMI (MCT T6) | — |
| Monitor 1 | ASUS PA278QV 27" (landscape) | 2560x1440 QHD |
| Monitor 2 | Samsung C24F390 23" (portrait) | 1920x1080 FHD |

### Driver Installation (MCT / j5create)

1. Download: https://download.j5create.com/driver/USB_Display_Adapters_Mac_Driver_11andLater/download.php
2. Install the `.pkg` (choose macOS 13–15 version)
3. System Settings → Privacy & Security → Allow "Magic Control Technology" system extension
4. System Settings → Privacy & Security → Screen Recording → Enable "USB Display Driver"
5. Reboot
6. Open `/Applications/USB Display.app` (must run after every reboot to load the driver)

## How It Works

```
[Virtual Display 1080x1920] ← your workspace, drag windows here
        |
  ScreenCaptureKit 60fps capture
        |
  CALayer transform rotate 90°
        |
[USB Display fullscreen window] ← physical monitor, rotated 90°
```

Instead of rotating the USB display (which macOS won't allow), we:

1. Create a **virtual portrait display** (1080x1920) using `CGVirtualDisplay` (undocumented CoreGraphics API, also used by Chromium and BetterDisplay)
2. Capture it at 60fps with **ScreenCaptureKit** + **IOSurface** zero-copy GPU path
3. Rotate the frames with a **CALayer transform** (GPU-side, no per-frame image processing)
4. Render fullscreen on the USB display

The virtual display is your workspace. The USB display is just a renderer.

### Wake Recovery

The stream automatically restarts after sleep/unlock — no manual intervention needed.

## Requirements

- macOS 14+ (ScreenCaptureKit, CGVirtualDisplay)
- Screen Recording permission
- A USB display adapter with driver installed

## Build

```bash
swiftc -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit \
  -framework QuartzCore -import-objc-header Bridge.h \
  main.swift -o portrait-display
```

## Usage

```bash
# List all displays
./portrait-display list

# Start (auto-detects 1920x1080 as portrait target)
./portrait-display start

# Start with specific target display ID
./portrait-display start <displayID>
```

Then:
1. Physically rotate your monitor 90°
2. System Settings → Displays → Arrange the "Portrait Virtual" display where you want it
3. Drag windows to the virtual display — they'll appear rotated on the physical monitor

## Auto-start (LaunchAgent)

```xml
<!-- ~/Library/LaunchAgents/com.local.portrait-display.plist -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.portrait-display</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/portrait-display</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

## Key Gotchas

These tripped me up during development:

1. **`vendorID` must be non-zero** — `CGVirtualDisplayDescriptor` silently returns `nil` if vendorID is 0. No error message.
2. **CALayer implicit animations cause ghosting** — Fix with `CATransaction.setDisableActions(true)` and setting `layer.actions` to disable all transitions.
3. **macOS 15 deprecated the old capture APIs** — `CGDisplayStream` and `CGDisplayCreateImage` no longer work. ScreenCaptureKit is the only option.
4. **Rotation direction matters** — `.pi / 2` vs `-.pi / 2` depends on how you physically mount your monitor. Try both.
5. **MCT driver needs USB Display.app running** — After every reboot, the system extension won't load until you open the app.

## Alternative: Hardware Approach

If you don't want to run a background process, there's a simpler (but less elegant) solution:

- **Portrait monitor** → Mac's native HDMI/USB-C port (supports rotation)
- **Landscape monitor** → j5create USB adapter

Trade-off: uses two ports instead of one, but zero latency and zero software dependencies.

## License

MIT
