local fs = require("filesystem")
local term = require("term")
local os = require("os")
local component = require("component")
local event = require("event")
local gpu = component.gpu
local keyboard = require("keyboard")

-- Config
local base_path         = "/home/gtnh_monitor/"
local mapping_file      = base_path .. "f_machine_mapping.lua"
local editor_script     = base_path .. "mapping_editor.lua"
local display_script    = base_path .. "machine_display.lua"

-- Vars
local screenW, screenH = gpu.maxResolution()

-- Helpers
local function clearScreen()
  gpu.fill(1, 1, screenW, screenH, " ")
end

local function centerText(y, text, color)
  local w = ({gpu.getResolution()})[1]
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  if color then gpu.setForeground(color) end
  gpu.set(x, y, text)
  gpu.setForeground(0xFFFFFF)
end

local function button(y, label, active, color, char, action)
  local inside = function(btn, tx, ty)
    return tx >= btn.x and tx <= btn.x + btn.w - 1 and ty == btn.y
  end

  local text = ""
  if not char then text = label 
  else text = "[" .. char .. "] " ..label 
  end

  local w = ({gpu.getResolution()})[1]
  local x = math.floor((w - #text) / 2) + 1
  if not active then
    gpu.setForeground(0x555555)
  elseif color then
    gpu.setForeground(color)
  end
  gpu.set(x, y, text)
  gpu.setForeground(0xFFFFFF)
  return {x = x, y = y, w = #text, h = 1, label = label, active = active, char = keyboard.keys[char], action = action, inside = inside}
end



-- Main
local function showMenu()
  gpu.setResolution(screenW, screenH)
  clearScreen()
  centerText(2, "== GT Machine Display Launcher ==", 0x00AAFF)

  local buttons = {}
  table.insert(buttons, button(5, "Edit Mapping", true, 0x00FF00, '1', (function() 
    clearScreen()
    centerText(3, "Launching Mapping Editor...", 0xAAAAFF)
    os.sleep(1)
    os.execute(editor_script)
  end)))

  if fs.exists(mapping_file) then
    table.insert(buttons, button(7, "Run Machine Display", true, 0x00FF00, '2', (function()
    clearScreen()
    centerText(3, "Launching Machine Display...", 0xAAAAFF)
    os.sleep(1)
    os.execute(display_script)
  end)))
  else
    table.insert(buttons, button(7, "Run Machine Display (no mapping)", false, nil, (function() end)))
  end

  table.insert(buttons, button(9, "Exit", true, 0xFF4444, '0', (function() 
    clearScreen()
    centerText(3, "Goodbye!", 0xFF4444)
    os.sleep(1)
    term.clear()
    os.exit()
  end)))
  return buttons
end

local function onKeyDown(char, buttons) 
  for _, btn in ipairs(buttons) do
    if btn.active and btn.char == char then btn.action() end
  end
end

local function onTouch(x, y, buttons)
  for _, btn in ipairs(buttons) do
    if btn.active and btn:inside(x,y) then btn.action() end
  end
end

local function handleEvent(buttons, eventType, ...)
  local arg = {...}

  if eventType == "key_down" then
    onKeyDown(arg[3], buttons)
  elseif eventType == "touch" then
    onTouch(arg[2], arg[3], buttons)
  end
end

-- Loop
while true do
  local buttons = showMenu()
  handleEvent(buttons, event.pull())
end
