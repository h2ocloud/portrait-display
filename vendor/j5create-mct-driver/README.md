# j5create MCT USB Display Driver (macOS 13–15)

Vendored copy of the j5create USB Display Adapter driver for macOS.

- **Version**: 4.1.0 (2025-01-12)
- **Chipset**: MCT T6 (Magic Control Technology, Vendor 0x0711)
- **Source**: https://download.j5create.com/driver/USB_Display_Adapters_Mac_Driver_11andLater/download.php
- **Archived**: 2026-04-08

## Why this is here

portrait-display depends on the MCT USB Display driver to function. If j5create
discontinues the driver or removes the download, this vendored copy ensures the
solution remains reproducible.

## Install

```bash
sudo installer -pkg "J5Create_Video_Adapter_Driver-4.1.0-2025-01-12.pkg" -target /
```

Then:
1. System Settings → Privacy & Security → Allow "Magic Control Technology" system extension
2. System Settings → Privacy & Security → Screen Recording → Enable "USB Display Driver"
3. Reboot
4. Open `/Applications/USB Display.app`

## Uninstall

```bash
sudo bash "uninstall-usb-display-driver copy.command"
```
