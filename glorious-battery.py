#!/usr/bin/env python3
"""Read remaining battery from a Glorious Model O 2 PRO.

The mouse does not expose charge through UPower or /sys/class/power_supply.
Glorious Core uses a vendor HID feature report on USB interface 2. This
script sends only that get-battery command (0x83). It does not change DPI,
RGB, polling rate, or profiles.

Verified on a Model O 2 PRO:
  258a:2035 — 4K/8KHz wireless receiver
  258a:201b — mouse on the charge cable (also seen as 1 kHz receiver mode)

The 0x83 reply keeps percent at byte 8. Byte 7 is the cable flag:
  0x00 wireless, 0x01 plugged in / charging.
Status byte 1 stays 0xA1 in both cases, so it cannot be used alone.
"""

from __future__ import annotations

import argparse
import fcntl
import glob
import json
import os
import sys
import time

VENDOR = 0x258A
# 201b is the mouse itself when the USB-C cable is in the front.
# The same PID also appears if the 2.4 GHz receiver drops to 1 kHz.
# Do not treat PID as the charge-state signal — use HID reply byte 7.
KNOWN_PIDS = {
    0x2035: "Model O 2 PRO 4K/8KHz receiver",
    0x201B: "Model O 2 PRO wired / 1 kHz",
    0x201A: "Glorious mouse wired/direct",
}

HIDIOCSFEATURE = lambda length: 0xC0004806 | (length << 16)
HIDIOCGFEATURE = lambda length: 0xC0004807 | (length << 16)

REPORT_LEN = 65
BATTERY_CMD = 0x83
QUERY_DELAY_S = 0.08

STATUS_MAP = {
    0xA0: "waking",
    0xA1: "discharging",
    0xA2: "unknown",
    0xA3: "unknown",
    0xA4: "asleep",
}


def _read_sys(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _hid_id_parts(hid_id: str) -> tuple[int, int] | None:
    parts = hid_id.split(":")
    if len(parts) != 3:
        return None
    try:
        return int(parts[1], 16), int(parts[2], 16)
    except ValueError:
        return None


def list_usb_mice() -> list[dict]:
    found = []
    for path in glob.glob("/sys/bus/usb/devices/*"):
        if _read_sys(os.path.join(path, "idVendor")) != f"{VENDOR:04x}":
            continue
        pid_text = _read_sys(os.path.join(path, "idProduct"))
        try:
            pid = int(pid_text, 16)
        except ValueError:
            continue
        found.append(
            {
                "sys": path,
                "pid": pid,
                "product": _read_sys(os.path.join(path, "product")) or KNOWN_PIDS.get(pid, "unknown"),
                "serial": _read_sys(os.path.join(path, "serial")),
            }
        )
    return found


def infer_connection(pid: int, usb_mice: list[dict], plugged: bool) -> str:
    if plugged:
        return "wired"
    if pid == 0x2035:
        return "wireless"
    if len(usb_mice) >= 2:
        return "wired"
    return "wireless"


def find_control_device() -> dict:
    matches = []
    for hid_dir in sorted(glob.glob("/sys/bus/hid/devices/0003:258A:*")):
        try:
            with open(os.path.join(hid_dir, "uevent"), encoding="utf-8") as fh:
                uevent = dict(line.strip().split("=", 1) for line in fh if "=" in line)
        except OSError:
            continue

        ids = _hid_id_parts(uevent.get("HID_ID", ""))
        if ids is None or ids[0] != VENDOR or ids[1] not in KNOWN_PIDS:
            continue

        hidraw_dir = os.path.join(hid_dir, "hidraw")
        try:
            hidraws = sorted(os.listdir(hidraw_dir))
        except OSError:
            continue
        if not hidraws:
            continue

        phys = uevent.get("HID_PHYS", "")
        matches.append(
            {
                "hid": os.path.basename(hid_dir),
                "name": uevent.get("HID_NAME", ""),
                "phys": phys,
                "iface": phys.rsplit("/", 1)[-1] if phys else "",
                "vid": ids[0],
                "pid": ids[1],
                "product": KNOWN_PIDS[ids[1]],
                "hidraw": hidraws[0],
                "path": f"/dev/{hidraws[0]}",
            }
        )

    if not matches:
        raise FileNotFoundError(
            "Glorious Model O 2 PRO not found (expected USB 258a:2035, 258a:201b, or wired 258a:201a)"
        )

    for entry in matches:
        if entry["iface"] == "input2":
            return entry
    return matches[-1]


def query_battery(path: str) -> dict:
    cmd = bytearray(REPORT_LEN)
    cmd[3] = 0x02
    cmd[4] = 0x02
    cmd[6] = BATTERY_CMD

    fd = os.open(path, os.O_RDWR)
    try:
        tx = bytearray(cmd)
        fcntl.ioctl(fd, HIDIOCSFEATURE(REPORT_LEN), tx, True)
        time.sleep(QUERY_DELAY_S)
        rx = bytearray(REPORT_LEN)
        fcntl.ioctl(fd, HIDIOCGFEATURE(REPORT_LEN), rx, True)
    finally:
        os.close(fd)

    reply = bytes(rx)
    if reply[6] != BATTERY_CMD:
        raise RuntimeError(
            f"unexpected reply command 0x{reply[6]:02x} (wanted 0x{BATTERY_CMD:02x})"
        )

    return {
        "percent": reply[8],
        "status": STATUS_MAP.get(reply[1], f"unmapped-0x{reply[1]:02x}"),
        "status_byte": reply[1],
        "flags_byte": reply[7],
        "plugged": reply[7] != 0,
        "raw": reply.hex(" "),
    }


def classify(device: dict, battery: dict, usb_mice: list[dict]) -> dict:
    plugged = bool(battery["plugged"])
    connection = infer_connection(device["pid"], usb_mice, plugged)
    hid_status = battery["status"]
    percent = battery["percent"]

    if hid_status == "asleep":
        state = "asleep"
    elif hid_status == "waking":
        state = "waking"
    elif plugged:
        state = "full" if percent >= 100 else "charging"
    elif hid_status == "discharging":
        state = "discharging"
    else:
        state = hid_status

    return {
        "ok": True,
        "state": state,
        "percent": percent,
        "connection": connection,
        "plugged": plugged,
        "hid_status": hid_status,
        "status_byte": battery["status_byte"],
        "flags_byte": battery["flags_byte"],
        "vid": f"{device['vid']:04x}",
        "pid": f"{device['pid']:04x}",
        "product": device["product"],
        "name": device["name"],
        "hidraw": device["path"],
        "interface": device["iface"],
        "usb_devices": len(usb_mice),
    }


def error_payload(state: str, message: str) -> dict:
    return {
        "ok": False,
        "state": state,
        "percent": None,
        "connection": "unknown",
        "error": message,
    }


def emit(payload: dict, args: argparse.Namespace, exit_code: int) -> int:
    if args.waybar:
        if payload.get("ok"):
            percent = payload["percent"]
            state = payload["state"]
            text = f"{percent}%"
            if state == "charging":
                text = f"{percent}%+"
            elif state == "full":
                text = f"{percent}%"
            css = "normal"
            if state in {"missing", "permission", "error"}:
                css = "critical"
            elif percent is not None and percent <= 15 and state == "discharging":
                css = "critical"
            elif percent is not None and percent <= 30 and state == "discharging":
                css = "warning"
            print(
                json.dumps(
                    {
                        "text": text,
                        "tooltip": (
                            f"{payload.get('name', 'Glorious mouse')}\n"
                            f"{state} · {payload.get('connection', '?')}\n"
                            f"USB {payload.get('vid', '?')}:{payload.get('pid', '?')}"
                        ),
                        "class": css,
                        "percentage": percent or 0,
                    }
                )
            )
        else:
            print(
                json.dumps(
                    {
                        "text": "?",
                        "tooltip": payload.get("error", "mouse battery unavailable"),
                        "class": "critical",
                        "percentage": 0,
                    }
                )
            )
        return exit_code

    if args.json:
        if args.verbose and "raw" in payload:
            print(json.dumps(payload, indent=2))
        else:
            print(json.dumps(payload))
        return exit_code

    if payload.get("ok"):
        print(f"{payload['percent']}% ({payload['state']}, {payload['connection']})")
    else:
        print(payload.get("error", "error"), file=sys.stderr)
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description="Read Glorious Model O 2 PRO battery over HID.")
    parser.add_argument("--json", action="store_true", help="machine-readable object")
    parser.add_argument("--waybar", action="store_true", help="Waybar custom-module JSON")
    parser.add_argument("--verbose", action="store_true", help="include raw HID reply")
    args = parser.parse_args()

    try:
        device = find_control_device()
        battery = query_battery(device["path"])
    except FileNotFoundError as exc:
        return emit(error_payload("missing", str(exc)), args, 2)
    except PermissionError:
        return emit(
            error_payload(
                "permission",
                f"permission denied opening hidraw (install 99-glorious-model-o2-pro.rules or run with sudo)",
            ),
            args,
            1,
        )
    except OSError as exc:
        return emit(error_payload("error", f"HID I/O failed: {exc}"), args, 1)
    except RuntimeError as exc:
        return emit(error_payload("error", str(exc)), args, 3)

    payload = classify(device, battery, list_usb_mice())
    if args.verbose:
        payload["raw"] = battery["raw"]
    return emit(payload, args, 0)


if __name__ == "__main__":
    sys.exit(main())
