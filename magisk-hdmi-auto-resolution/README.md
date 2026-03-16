# HDMI Auto Resolution Switch

Magisk module for Android 15 tablets that:

- switches to `1440x2560` and `160 DPI` after external video output becomes active
- switches back to `2400x3392` and `420 DPI` after external video output stops

## How it works

The module runs a Magisk `service.sh` loop after boot.

Detection order:

1. check `/sys/class/drm/*/status` for external connectors like HDMI / DP / USB-C alt mode
2. fallback to `dumpsys display` and `cmd display get-displays`

When state changes, it runs:

```sh
wm size 1440x2560
wm density 160
```

or:

```sh
wm size 2400x3392
wm density 420
```

## Install

1. Zip the folder contents or use the provided release zip.
2. Install from Magisk.
3. Reboot once after installation.

## Logs

Module log path:

```text
/data/adb/modules/hdmi_auto_resolution/hdmi_auto_resolution.log
```

## Notes

- Vendor ROMs expose external display state differently. If your ROM does not report HDMI / DP in DRM or `dumpsys display`, you will need to adjust the detection rules in `service.sh`.
- The module changes the tablet's default display override. It does not directly rewrite EDID or external monitor timing.
