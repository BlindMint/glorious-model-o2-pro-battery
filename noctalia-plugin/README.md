# Noctalia plugin: Mouse Battery

Local plugin for the C++ Noctalia bar (`plugin_api = 3`).

- id: `samurai/mouse-battery`
- widget entry: `battery` (`widget.luau`)
- reader: `glorious-battery.py --json` (copied into the plugin directory)

Install from the parent directory:

```bash
../install.sh
```

That copies this plugin plus `glorious-battery.py` to:

```
~/.local/share/noctalia-bar/noctalia/plugins/mouse-battery/
```

Restart Noctalia after install. The widget classifies charge from the reader’s `state` field (`charging` / `discharging` / `full` / …), which is derived from HID reply byte 7, not from the USB product ID. See the parent `README.md`.
