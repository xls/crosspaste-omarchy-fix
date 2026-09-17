# CrossPaste on Omarchy

Installs [CrossPaste](https://github.com/CrossPaste/crosspaste-desktop) on
Omarchy (Arch + Hyprland) and works around the fact that CrossPaste is a
Java/XWayland app that cannot see the Wayland clipboard.

```
./install.sh            # install or update everything (safe to re-run)
./install.sh status     # state of every piece + recent journal lines
./install.sh logs       # follow the path-sync service log
./install.sh uninstall  # remove the integration, keep the package
```

Run `install.sh` from a terminal; the AUR step needs your sudo password.

## What it sets up

| Piece | Purpose |
|---|---|
| `crosspaste-desktop-bin` (AUR) + `libxcrypt-compat` | The app, and the lib its bundled `crosspaste-cli` needs |
| `~/.local/bin/crosspaste-push` | Run by Super+C: pipes the Wayland clipboard text into `crosspaste-cli copy` |
| `~/.config/hypr/crosspaste.lua` | Rebinds Super+C to Omarchy's universal copy followed by `crosspaste-push`; required from `bindings.lua` |
| `~/.local/bin/crosspaste-path-sync` + `crosspaste-path-sync.service` | Watches `crosspaste-cli watch`; when an image/file paste arrives it puts the local file path on the Wayland clipboard, so terminals paste the path |
| `shell.json` tray pin | Keeps the CrossPaste tray icon visible on the Omarchy bar instead of inside the collapsed drawer |
| ufw rules (only if ufw is active) | Allows CrossPaste's sync port (13129/tcp by default, read from `crosspaste-cli status`) and mDNS 5353/udp so other devices can discover and reach this machine |

## Why

Hyprland only hands the clipboard selection to the focused client. XWayland
therefore learns about a copy only when an X11 window is focused, so CrossPaste
misses everything copied in kitty, Brave and other native Wayland apps. The
reverse direction works, but Hyprland's XWayland bridge exposes CrossPaste's
image/file clipboard as an empty text entry to Wayland apps. The two scripts
paper over each direction.

## Known limits

- Only Super+C pushes into CrossPaste; plain Ctrl+C / Ctrl+Shift+C do not.
- Pushing re-sets the clipboard as plain text (rich HTML is dropped).
- The path-sync fires on *new* image/file pastes. Picking an old image from the
  CrossPaste window still pastes nothing in Wayland apps.
- Your other CrossPaste devices may echo pushed items back as "remote" entries.

## Firewall

Omarchy ships ufw with `default deny incoming`. Other devices reach this
machine on CrossPaste's sync port (13129/tcp) and discover it via mDNS
(5353/udp), so both need an allow rule when ufw is active. The installer adds
them if ufw is running and skips the step (with a note) if it is not; re-run
`./install.sh` after enabling ufw. `uninstall` removes only the rules it added.

## Debugging

```
journalctl --user -u crosspaste-path-sync -f
tail -f ~/.local/share/.crosspaste/logs/crosspaste.log
/opt/crosspaste/lib/app/bin/crosspaste-cli status | history | devices
hyprctl binds | grep -A3 'CrossPaste'
```
