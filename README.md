# Glorious Model O 2 PRO battery on Linux

The Model O 2 PRO does not publish charge through UPower, `/sys/class/power_supply`, or the standard HID Battery page. Glorious Core on Windows reads it over a vendor HID feature report on USB interface 2. This directory is a Linux reader for that report, plus a Noctalia bar plugin.

## What we measured on this machine (2026-08-14)

| Setup | USB ID | Serial | Reply bytes 1, 7, 8 | Classified as |
|---|---|---|---|---|
| Dongle in the USB cable (2.4 GHz) | `258a:2035` | `7BD1A7F074155054` | `a1 00 32` then `a1 00 31` | discharging, 50% then 49% |
| USB-C cable in the front of the mouse | `258a:201b` | `7BBD2152ED635054` | `a1 01 31` | charging, 49%, wired |

Status byte 1 stays `0xA1` in both cases. **Byte 7 is the cable flag** (`0x00` wireless, `0x01` plugged in). Percent is byte 8.

`258a:201b` is *not* “wireless only.” It is the mouse itself when the charge cable is in, and it also appears if the receiver drops to 1 kHz. Do not use PID to decide charging.

## Quick start

```bash
python3 ./glorious-battery.py
# 49% (charging, wired)   # cable in
# 49% (discharging, wireless)

python3 ./glorious-battery.py --json
python3 ./glorious-battery.py --verbose
```

`--json` is what the Noctalia widget runs. Example while charging:

```json
{
  "ok": true,
  "state": "charging",
  "percent": 49,
  "connection": "wired",
  "plugged": true,
  "hid_status": "discharging",
  "status_byte": 161,
  "flags_byte": 1,
  "vid": "258a",
  "pid": "201b"
}
```

`hid_status` is the raw byte-1 label from the sibling-mouse map. `state` is the usable value after applying byte 7.

hidraw is `root:root` `0600` until the udev rule is installed. That rule is already on this machine at `/etc/udev/rules.d/99-glorious-model-o2-pro.rules`. You are in the `input` group, so the reader works without sudo. To install it elsewhere:

```bash
sudo cp 99-glorious-model-o2-pro.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug/replug, or log out/in.

## What Linux already exposes (and does not)

| Interface | Present on this mouse? |
|---|---|
| `/sys/class/power_supply/` | No mouse entry. |
| UPower | Only `DisplayDevice` on this desktop. |
| Standard HID Battery System page `0x85` | Not advertised. `CONFIG_HID_BATTERY_STRENGTH=y` therefore does nothing. |
| Bluetooth battery | Not applicable. 2.4 GHz dongle or a USB cable, not BT. |
| Piper / libratbag / hid-glorious | These PIDs are not supported. `hid-generic` binds. |

Three HID interfaces (hidraw numbers move; look up interface 2 via `HID_PHYS` ending in `/input2`):

| Interface | Typical node | Role |
|---|---|---|
| 0 | `/dev/hidraw5` | Boot mouse. No battery. |
| 1 | `/dev/hidraw6` | Keyboard + consumer + vendor input reports 4 and 5. Those do not stream charge. |
| 2 | `/dev/hidraw7` | Vendor **feature** report, 64 bytes, no report ID, usage page `0xFFFF`. Glorious Core channel. |

## Protocol

Send a 65-byte HID feature report (leading `0x00` report ID, then 64 data bytes) to interface 2, wait ~80 ms, then read the same feature report back. Read only — not a DPI, RGB, or profile write.

Request (only these bytes are non-zero):

| Offset | Value | Meaning |
|---|---|---|
| 0 | `0x00` | Report ID (device has none) |
| 3 | `0x02` | Command family |
| 4 | `0x02` | Length / subcommand style field |
| 6 | `0x83` | Get battery |

Wireless reply:

```
00 a1 00 02 02 00 83 00 31 ...
```

Wired / charging reply:

```
00 a1 00 02 02 00 83 01 31 ...
```

| Offset | Wireless | Wired | Meaning |
|---|---|---|---|
| 1 | `0xA1` | `0xA1` | Status. **Does not change** when you plug in. |
| 3 | `0x02` | `0x02` | Echo |
| 4 | `0x02` | `0x02` | Echo |
| 6 | `0x83` | `0x83` | Echo of get-battery. If this is not `0x83`, ignore the packet. |
| 7 | `0x00` | `0x01` | Cable flag. This is how we tell charging from discharging. |
| 8 | percent | percent | Remaining charge, 0–100 |

Byte 1 map (from [louis4craft/glorious-ctl](https://github.com/louis4craft/glorious-ctl), sibling Model D 2 PRO 4K):

| Byte 1 | Meaning |
|---|---|
| `0xA1` | Active (wireless or wired). Not “discharging” by itself. |
| `0xA4` | Asleep |
| `0xA0` | Waking |
| `0xA2`, `0xA3` | Other / unknown |

Classification used by `glorious-battery.py`:

- byte 7 ≠ 0 and percent &lt; 100 → `charging`
- byte 7 ≠ 0 and percent ≥ 100 → `full`
- byte 7 = 0 and byte 1 = `0xA1` → `discharging`
- byte 1 = `0xA4` → `asleep`

The older wired Model O Sinowealth driver in libratbag uses 6-byte reports with IDs `0x04`/`0x05`. That is a different packet layout.

## Why a Windows VM did not work

Glorious Core needs exclusive access to interface 2. The receiver is a poor USB-passthrough device: three HID interfaces, 480 Mbps, 4K/8K interrupt rate, and it re-enumerates (`201b` ↔ `2035`). VMs often keep only the boot-mouse interface or drop the device on re-enumeration. Native Windows works because Core talks to interface 2 on bare metal.

## Noctalia bar widget

This machine runs the C++ Noctalia bar from `~/dev/arch_setup/quickshell/noctalia`, not the older QML `noctalia-shell` clone in `~/dev/quickshell-inspiration/`.

Install a real copy under Noctalia's user plugin directory (no symlink back to this checkout):

```bash
./install.sh
# restart Noctalia after this (quit the bar and start noctalia-bar again)
```

`./install.sh --udev` also copies the hidraw rule to `/etc/udev/rules.d/` if it is not already there. `./install.sh --uninstall` removes the copied plugin.

| | |
|---|---|
| Source | `noctalia-plugin/` plus `glorious-battery.py` |
| Installed | `~/.local/share/noctalia-bar/noctalia/plugins/mouse-battery/` |
| Plugin id | `samurai/mouse-battery` |
| Bar entry | `samurai/mouse-battery:battery` |

Enabled in Noctalia Settings → Plugins, and added from the bar widget picker. The hybrid profile pins it on the right side of the bar. The widget polls the copied `glorious-battery.py` on its refresh interval.

| State | When | Icon |
|---|---|---|
| discharging | byte 7 = 0, awake | `battery-1` … `battery-4` by percent |
| charging | byte 7 = 1, below 100% | `battery-charging` |
| full | byte 7 = 1, 100% | `plug-filled` |
| asleep | HID status `0xA4` | `battery` |
| missing | no matching USB device | `battery-off` |
| permission / error | hidraw not readable, or a bad reply | `battery-exclamation` |

Widget settings: refresh interval, show/hide the percent label, hide when disconnected, low-battery warning threshold, path to `glorious-battery.py`.

## Omarchy Quattro bar

Omarchy Quattro’s default bar is `omarchy-shell`, not Waybar. `./install.sh` copies the reader to `~/.config/omarchy/bar/scripts/glorious-battery.py`. The widget is a command module in `~/.config/omarchy/shell.json`, on the right, immediately after the tray:

```json
{
  "id": "mouse-battery",
  "type": "command",
  "exec": "~/.config/omarchy/bar/scripts/glorious-battery.py --waybar",
  "interval": 60,
  "tooltip": "Mouse battery"
}
```

The reader’s `--waybar` JSON (`text`, `tooltip`, `class`) is what the shell command module consumes.

## Waybar (legacy)

```jsonc
"custom/mouse-battery": {
    "exec": "~/.config/omarchy/bar/scripts/glorious-battery.py --waybar",
    "return-type": "json",
    "interval": 60,
    "tooltip": true
}
```

## Hardware fallback

Hold the DPI button. The RGB strips blink a color for a charge band. That is not machine-readable.

## Related software

- [louis4craft/glorious-ctl](https://github.com/louis4craft/glorious-ctl) — Linux GUI for several Glorious wireless mice, including Model D 2 PRO 4K (`258a:2036`). Same 0x83 packet; it takes `wired` as a caller argument instead of reading byte 7. This O 2 PRO is not in their `devices.json` yet.
- [korkje/mxw](https://github.com/korkje/mxw) — older Model O/D Wireless (`258a:2022` and friends).
- Official Glorious Core — Windows only.

## Files

| File | Purpose |
|---|---|
| `glorious-battery.py` | HID reader. Stdlib only. `--json` / `--waybar` / `--verbose`. |
| `99-glorious-model-o2-pro.rules` | hidraw access for `258a:2035` and `258a:201b`. Installed on this machine. |
| `noctalia-plugin/plugin.toml` | Plugin manifest (API 3). |
| `noctalia-plugin/widget.luau` | Bar widget. Polls the reader. |
| `noctalia-plugin/translations/en.json` | Settings labels. |
| `install.sh` | Copy the plugin/reader into Noctalia’s plugin dir and `~/.config/omarchy/bar/scripts/`. |
| `README.md` | This note. |
