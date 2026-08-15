#!/usr/bin/env bash
# Copy the Noctalia plugin and HID reader into Noctalia's local plugin dir.
# Does not symlink back to this checkout.
set -euo pipefail

PLUGIN_ID="samurai/mouse-battery"
PLUGIN_DIRNAME="mouse-battery"
UDEV_RULE_NAME="99-glorious-model-o2-pro.rules"

src_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
do_udev=false
do_uninstall=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Install copies of the HID reader (no symlink back to this checkout):

  ~/.local/share/noctalia-bar/noctalia/plugins/mouse-battery/   (Noctalia)
  ~/.config/omarchy/bar/scripts/glorious-battery.py             (Omarchy shell)

Options:
  --udev        Also install the hidraw udev rule (needs sudo)
  --uninstall   Remove the copied plugin/script files
  -h, --help    Show this help

After a Noctalia install, restart Noctalia. The Omarchy shell command
module is configured in ~/.config/omarchy/shell.json.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

xdg_data_home() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# Match noctalia-bar's NOCTALIA_DATA_HOME when that wrapper is in use.
plugin_root() {
  if [[ -n "${NOCTALIA_DATA_HOME:-}" ]]; then
    printf '%s/noctalia/plugins\n' "${NOCTALIA_DATA_HOME%/}"
    return
  fi

  local xdg_data
  xdg_data=$(xdg_data_home)
  if [[ -d "$xdg_data/noctalia-bar/noctalia" ]] || command -v noctalia-bar >/dev/null 2>&1; then
    printf '%s/noctalia-bar/noctalia/plugins\n' "$xdg_data"
    return
  fi

  printf '%s/noctalia/plugins\n' "$xdg_data"
}

plugin_dest() {
  printf '%s/%s\n' "$(plugin_root)" "$PLUGIN_DIRNAME"
}

omarchy_script_dest() {
  printf '%s/.config/omarchy/bar/scripts/glorious-battery.py\n' "$HOME"
}

require_sources() {
  local missing=0
  local path
  for path in \
    "$src_root/glorious-battery.py" \
    "$src_root/noctalia-plugin/plugin.toml" \
    "$src_root/noctalia-plugin/widget.luau" \
    "$src_root/noctalia-plugin/translations/en.json"
  do
    if [[ ! -f "$path" ]]; then
      printf 'missing source file: %s\n' "$path" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "refusing to install; source tree is incomplete"
}

install_plugin() {
  require_sources

  local dest dest_root stage
  dest=$(plugin_dest)
  dest_root=$(plugin_root)
  mkdir -p "$dest_root"

  stage=$(mktemp -d "${TMPDIR:-/tmp}/mouse-battery.XXXXXX")
  cleanup_stage() { rm -rf "$stage"; }
  trap cleanup_stage EXIT

  mkdir -p "$stage/$PLUGIN_DIRNAME/translations"
  cp -- "$src_root/noctalia-plugin/plugin.toml" "$stage/$PLUGIN_DIRNAME/"
  cp -- "$src_root/noctalia-plugin/widget.luau" "$stage/$PLUGIN_DIRNAME/"
  cp -- "$src_root/noctalia-plugin/translations/en.json" "$stage/$PLUGIN_DIRNAME/translations/"
  cp -- "$src_root/glorious-battery.py" "$stage/$PLUGIN_DIRNAME/glorious-battery.py"
  chmod 755 "$stage/$PLUGIN_DIRNAME/glorious-battery.py"

  # Replace a previous copy or the old broken symlink.
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -rf -- "$dest"
  fi
  mv -- "$stage/$PLUGIN_DIRNAME" "$dest"
  trap - EXIT
  rm -rf "$stage"

  printf 'Installed %s -> %s\n' "$PLUGIN_ID" "$dest"
  printf 'Reader: %s/glorious-battery.py\n' "$dest"
}

install_omarchy_script() {
  local dest dest_dir
  dest=$(omarchy_script_dest)
  dest_dir=$(dirname -- "$dest")
  mkdir -p "$dest_dir"
  cp -- "$src_root/glorious-battery.py" "$dest"
  chmod 755 "$dest"
  printf 'Installed Omarchy reader -> %s\n' "$dest"
}

uninstall_plugin() {
  local dest omarchy_dest
  dest=$(plugin_dest)
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    printf 'Nothing to remove at %s\n' "$dest"
  else
    rm -rf -- "$dest"
    printf 'Removed %s\n' "$dest"
    printf 'Disable %s in Noctalia Settings → Plugins if it is still listed.\n' "$PLUGIN_ID"
  fi

  omarchy_dest=$(omarchy_script_dest)
  if [[ -e "$omarchy_dest" || -L "$omarchy_dest" ]]; then
    rm -f -- "$omarchy_dest"
    printf 'Removed %s\n' "$omarchy_dest"
  fi
}

udev_dest() {
  printf '/etc/udev/rules.d/%s\n' "$UDEV_RULE_NAME"
}

install_udev() {
  local src dest
  src="$src_root/$UDEV_RULE_NAME"
  dest=$(udev_dest)
  [[ -f "$src" ]] || die "missing udev rule: $src"

  if [[ -f "$dest" ]]; then
    printf 'udev rule already present: %s\n' "$dest"
    return
  fi

  sudo cp -- "$src" "$dest"
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  printf 'Installed udev rule: %s\n' "$dest"
  printf 'Unplug and replug the mouse/receiver, or log out and back in.\n'
}

report_udev() {
  local dest
  dest=$(udev_dest)
  if [[ -f "$dest" ]]; then
    printf 'udev rule: %s (already installed)\n' "$dest"
  else
    printf 'udev rule not installed. hidraw access needs:\n'
    printf '  %s --udev\n' "$0"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udev)
      do_udev=true
      shift
      ;;
    --uninstall)
      do_uninstall=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$do_uninstall" == true ]]; then
  uninstall_plugin
  exit 0
fi

install_plugin
install_omarchy_script
if [[ "$do_udev" == true ]]; then
  install_udev
else
  report_udev
fi

cat <<EOF

Restart Noctalia so it reloads the plugin (quit the bar and start noctalia-bar again).
The plugin is already enabled as ${PLUGIN_ID} if you used it before.
EOF
