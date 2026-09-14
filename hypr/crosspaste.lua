-- CrossPaste integration for Omarchy. Loaded from ~/.config/hypr/bindings.lua
-- via require("hypr.crosspaste"); installed by crosspaste-omarchy/install.sh.
--
-- Super+C: Omarchy's universal copy, plus push the copied text into CrossPaste.
-- CrossPaste runs under XWayland and cannot see the Wayland clipboard, so
-- ~/.local/bin/crosspaste-push hands it the text through crosspaste-cli.
-- The helpers mirror /usr/share/omarchy/default/hypr/bindings/clipboard.lua.

local function send_shortcut_once(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end

local function active_window_is_terminal()
  local window = hl.get_active_window()
  if not window then
    return false
  end
  for _, tag in ipairs(window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then
      return true
    end
  end
  return false
end

hl.unbind("SUPER + C")
o.bind("SUPER + C", "Universal copy (+ CrossPaste)", function()
  if active_window_is_terminal() then
    send_shortcut_once("CTRL", "Insert")
  else
    send_shortcut_once("CTRL", "C")
  end
  hl.timer(function()
    hl.exec_cmd(os.getenv("HOME") .. "/.local/bin/crosspaste-push")
  end, { timeout = 250, type = "oneshot" })
end)
