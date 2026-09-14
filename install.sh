#!/bin/bash
# CrossPaste on Omarchy (Arch + Hyprland): install, wire up, or remove.
#
#   ./install.sh            install / update everything (idempotent)
#   ./install.sh status     show the state of every piece plus recent logs
#   ./install.sh logs       follow the path-sync service journal
#   ./install.sh uninstall  remove the integration (keeps the CrossPaste package)
#
# What "install" does:
#   1. crosspaste-desktop-bin (AUR) + libxcrypt-compat (needed by crosspaste-cli)
#   2. ~/.local/bin/crosspaste-push       Super+C -> push clipboard text into CrossPaste
#   3. ~/.local/bin/crosspaste-path-sync  synced image/file -> its local path on the clipboard
#   4. ~/.config/hypr/crosspaste.lua      the Super+C binding, required from bindings.lua
#   5. systemd --user crosspaste-path-sync.service, enabled and started
#   6. pins the CrossPaste tray icon on the Omarchy bar (shell.json)
#   7. starts CrossPaste if it is not running (it registers its own autostart)
#
# Run it from a terminal: the package step asks for your sudo password.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
HYPR_DIR="$HOME/.config/hypr"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
CLI=/opt/crosspaste/lib/app/bin/crosspaste-cli
REQUIRE_LINE='require("hypr.crosspaste")'
TRAY_ID="1" # CrossPaste's StatusNotifierItem Id, as the tray keys items

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

backup() { [[ -f $1 ]] && cp -p "$1" "$1.bak.$(date +%s)"; }

install_packages() {
  log "Packages"
  command -v yay >/dev/null || die "yay not found; install it first"
  if pacman -Q crosspaste-desktop-bin libxcrypt-compat >/dev/null 2>&1; then
    ok "crosspaste-desktop-bin and libxcrypt-compat already installed"
  else
    yay -S --needed crosspaste-desktop-bin libxcrypt-compat
  fi
  [[ -x $CLI ]] || die "crosspaste-cli missing at $CLI"
  "$CLI" version >/dev/null 2>&1 || die "crosspaste-cli does not run (missing libcrypt.so.1?)"
  ok "crosspaste-cli runs"
}

install_scripts() {
  log "Scripts -> $BIN_DIR"
  mkdir -p "$BIN_DIR"
  install -m 755 "$HERE/bin/crosspaste-push" "$BIN_DIR/crosspaste-push"
  install -m 755 "$HERE/bin/crosspaste-path-sync" "$BIN_DIR/crosspaste-path-sync"
  ok "crosspaste-push, crosspaste-path-sync"
}

install_binding() {
  log "Hyprland Super+C binding"
  mkdir -p "$HYPR_DIR"
  install -m 644 "$HERE/hypr/crosspaste.lua" "$HYPR_DIR/crosspaste.lua"
  if grep -qF "$REQUIRE_LINE" "$HYPR_DIR/bindings.lua" 2>/dev/null; then
    ok "bindings.lua already requires hypr.crosspaste"
  else
    backup "$HYPR_DIR/bindings.lua"
    printf '\n-- CrossPaste: Super+C also pushes the copy into CrossPaste (see hypr/crosspaste.lua)\n%s\n' \
      "$REQUIRE_LINE" >>"$HYPR_DIR/bindings.lua"
    ok "added $REQUIRE_LINE to bindings.lua"
  fi
  if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null
    local errs
    errs=$(hyprctl configerrors 2>/dev/null | sed '/^\s*$/d' || true)
    if [[ -n $errs ]]; then
      warn "hyprctl configerrors reported:"; printf '%s\n' "$errs"
    else
      ok "Hyprland reloaded, no config errors"
    fi
  else
    warn "not inside Hyprland; binding takes effect at next login"
  fi
}

install_service() {
  log "systemd user service crosspaste-path-sync"
  mkdir -p "$UNIT_DIR"
  install -m 644 "$HERE/systemd/crosspaste-path-sync.service" "$UNIT_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now crosspaste-path-sync.service >/dev/null 2>&1 || true
  systemctl --user restart crosspaste-path-sync.service
  ok "$(systemctl --user is-enabled crosspaste-path-sync.service) / $(systemctl --user is-active crosspaste-path-sync.service)"
}

pin_tray_icon() {
  log "Omarchy bar tray pin"
  [[ -f $SHELL_JSON ]] || { warn "$SHELL_JSON not found, skipping"; return; }
  command -v jq >/dev/null || { warn "jq not found, skipping"; return; }
  if jq -e --arg id "$TRAY_ID" '
      [.bar.layout[]?[]? | select(.id == "omarchy.tray") | (.pinned // []) | index($id)] | any(. != null)
    ' "$SHELL_JSON" >/dev/null; then
    ok "tray item already pinned"
    return
  fi
  backup "$SHELL_JSON"
  local tmp; tmp=$(mktemp)
  jq --arg id "$TRAY_ID" '
      .bar.layout |= with_entries(.value |= map(
        if .id == "omarchy.tray" then .pinned = ((.pinned // []) + [$id] | unique) else . end))
    ' "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
  ok "pinned CrossPaste on the bar (shell.json hot-reloads)"
}

start_crosspaste() {
  log "CrossPaste app"
  if "$CLI" --no-start status >/dev/null 2>&1; then
    ok "already running"
  else
    setsid -f /usr/bin/crosspaste --minimize >/dev/null 2>&1
    ok "started (it registers its own autostart entry on first run)"
  fi
}

do_install() {
  install_packages
  install_scripts
  install_binding
  install_service
  pin_tray_icon
  start_crosspaste
  echo
  log "Done. Try: select text, press Super+C, then check '$CLI history'."
  echo "    ./install.sh status   |   ./install.sh logs"
}

do_status() {
  log "Packages";  pacman -Q crosspaste-desktop-bin libxcrypt-compat 2>&1 | sed 's/^/   /'
  log "CrossPaste"; "$CLI" --no-start status 2>&1 | sed 's/^/   /' || true
  log "Devices";   "$CLI" --no-start devices 2>&1 | grep -E 'Platform|State|^  [A-Za-z]' | sed 's/^/   /' || true
  log "Super+C binding"
  if command -v hyprctl >/dev/null; then
    hyprctl binds -j 2>/dev/null | jq -r '.[] | select(.key=="C" and .modmask==64) | "   \(.description)"' || true
  fi
  grep -qF "$REQUIRE_LINE" "$HYPR_DIR/bindings.lua" 2>/dev/null && ok "bindings.lua requires hypr.crosspaste" || warn "require line missing in bindings.lua"
  [[ -x $BIN_DIR/crosspaste-push ]] && ok "crosspaste-push installed" || warn "crosspaste-push missing"
  log "Path-sync service"
  systemctl --user --no-pager status crosspaste-path-sync.service 2>&1 | sed -n '1,4p' | sed 's/^/   /'
  log "Tray pin"
  jq -r --arg id "$TRAY_ID" '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | .pinned // []] | flatten | if index($id) then "   pinned" else "   not pinned" end' "$SHELL_JSON" 2>/dev/null || true
  log "Recent journal (crosspaste-path-sync)"
  journalctl --user -u crosspaste-path-sync -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/   /'
  log "Recent CrossPaste warnings"
  tail -n 200 "$HOME/.local/share/.crosspaste/logs/crosspaste.log" 2>/dev/null | grep -E 'WARN|ERROR' | tail -5 | cut -c1-140 | sed 's/^/   /'
}

do_logs() {
  exec journalctl --user -u crosspaste-path-sync -f -o cat
}

do_uninstall() {
  log "Removing integration (CrossPaste package left in place)"
  systemctl --user disable --now crosspaste-path-sync.service 2>/dev/null || true
  rm -f "$UNIT_DIR/crosspaste-path-sync.service"; systemctl --user daemon-reload
  rm -f "$BIN_DIR/crosspaste-push" "$BIN_DIR/crosspaste-path-sync" "$HYPR_DIR/crosspaste.lua"
  if grep -qF "$REQUIRE_LINE" "$HYPR_DIR/bindings.lua" 2>/dev/null; then
    backup "$HYPR_DIR/bindings.lua"
    sed -i "/^-- CrossPaste: Super+C also pushes/d; /^require(\"hypr.crosspaste\")$/d" "$HYPR_DIR/bindings.lua"
  fi
  if [[ -f $SHELL_JSON ]] && command -v jq >/dev/null; then
    backup "$SHELL_JSON"
    local tmp; tmp=$(mktemp)
    jq --arg id "$TRAY_ID" '.bar.layout |= with_entries(.value |= map(
        if .id == "omarchy.tray" and .pinned then .pinned -= [$id] else . end))' "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
  fi
  rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/crosspaste-push"
  command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
  ok "removed. To drop the app too: yay -Rns crosspaste-desktop-bin"
}

case "${1:-install}" in
  install)   do_install ;;
  status)    do_status ;;
  logs)      do_logs ;;
  uninstall) do_uninstall ;;
  *) echo "usage: $0 [install|status|logs|uninstall]" >&2; exit 2 ;;
esac
