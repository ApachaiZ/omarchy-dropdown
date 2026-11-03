-- Omarchy Dropdown : optional keyboard integration.
--
-- Add this file at ~/.config/hypr/dropdown.lua, then load it once from
-- ~/.config/hypr/hyprland.lua:
--
--   require("hypr.dropdown")
--
-- Both prefixes open the same palette. The modifiers do not have to stay
-- held: Hyprland releases them, the palette keeps keyboard focus and waits
-- for the next key. Edit or remove either bind here. Set a prefix to nil to
-- disable it.

local primary = "SUPER + ALT + SEMICOLON"
local secondary = "SUPER + SEMICOLON" -- optional; nil disables it

if primary then
  o.bind(primary, "Dropdown palette", "omarchy-shell shell toggle apach.dropdown", { submap_universal = true })
end

if secondary then
  o.bind(secondary, "Dropdown palette (secondary)", "omarchy-shell shell toggle apach.dropdown", { submap_universal = true })
end

-- Optional: switch the visible dropdown from anywhere. This steals Ctrl+Tab
-- from every application, so it is commented out by default. The in-palette
-- Ctrl+Tab and the "next open window" command key need no bind.
-- o.bind("CTRL + TAB", "Dropdown next window", "omarchy-shell apach.dropdown next")
-- o.bind("CTRL + SHIFT + TAB", "Dropdown previous window", "omarchy-shell apach.dropdown previous")

-- A direct, prefix-free way to reach a managed application, if you prefer:
--   o.bind("SUPER + SHIFT + T", "Terminal dropdown", "omarchy-shell apach.dropdown showApp system.terminal")

-- Direct application shortcuts configured in Dropdown (Manage → D).
-- The plugin generates this file; it is safe to delete when the feature is
-- unused. Loaded here so the binds survive Hyprland restarts.
local generatedBinds = (os.getenv("HOME") or "") .. "/.config/hypr/dropdown-binds.lua"
local generatedFile = io.open(generatedBinds, "r")
if generatedFile then
  generatedFile:close()
  dofile(generatedBinds)
end

-- dropdown-preemption-hook v1
-- Launch preemption. Dropdown arms `_dropdownPending` just before it starts
-- an app and clears it once the window is adopted. Running inside the
-- compositor means the window is floated, moved to its parking workspace and
-- made transparent in the same pass that maps it, before it is ever painted.
-- Window rules cannot do this: Chromium and Electron create their toplevel
-- before the rule engine can see the class, while this handler sees it.
local function ddHas(haystack, needle)
  if not needle or needle == "" then return false end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

hl.on("window.open", function(window)
  local pending = _dropdownPending
  if type(pending) ~= "table" then return end
  local now = os.time()
  for key, entry in pairs(pending) do
    if type(entry) ~= "table" or type(entry.workspace) ~= "string" then
      pending[key] = nil
    elseif entry.expires and entry.expires < now then
      pending[key] = nil
    elseif not entry.used and (ddHas(window.class, entry.class) or ddHas(window.title, entry.title)) then
      entry.used = true
      hl.dispatch(hl.dsp.window.float({ action = "enable", window = window }))
      hl.dispatch(hl.dsp.window.set_prop({ window = window, prop = "opacity", value = "0" }))
      hl.dispatch(hl.dsp.window.move({ workspace = entry.workspace, follow = false, window = window }))
      hl.dispatch(hl.dsp.window.tag({ tag = "+dropdown-hidden", window = window }))
    end
  end
end)

-- Bare Escape while a dropdown is visible. The service enters this submap
-- when it shows a managed window and resets it when the window is hidden.
hl.define_submap("apach-dropdown", function()
  hl.bind("Escape", function()
    hl.dispatch(hl.dsp.exec_cmd("omarchy-shell apach.dropdown reduce"))
    hl.dispatch(hl.dsp.submap("reset"))
  end)
  -- A real left click while a dropdown is visible: the service hides it
  -- immediately when the click is outside the window, like Escape, and
  -- ignores clicks inside it. non_consuming keeps the click for the window
  -- under the pointer, so normal clicking is unchanged.
  hl.bind("mouse:272", function()
    hl.dispatch(hl.dsp.exec_cmd("omarchy-shell -q apach.dropdown clicked"))
  end, { non_consuming = true })
end)
