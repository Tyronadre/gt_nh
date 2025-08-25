-- installer.lua
-- Simple installer for GTNH Machine Monitor scripts

local fs = require("filesystem")
local shell = require("shell")
local term = require("term")

-- === CONFIG ===
local scripts = {
  launcher = [[
local fs    = require("filesystem")
local term  = require("term")
local os    = require("os")
local component = require("component")
local gpu   = component.gpu

-- Config
local mapping_file      = "/home/f_machine_mapping.lua"
local editor_script     = "/home/mapping_editor.lua"
local display_script    = "/home/machine_display.lua"

-- Vars
local screenW, screenH = gpu.getResolution()

local function clearScreen()
  gpu.setResolution(screenW, screenH)
  term.clear()
  term.setCursor(1,1)
end

local function pause()
  io.write("\nPress Enter to continue...")
  io.read()
end

local function showMenu()
  clearScreen()
  print("== Machine Array Launcher ==")
  print()
  print("1) Edit mapping")
  if fs.exists(mapping_file) then
    print("2) Run machine array display")
  else
    print("2) Run machine array display (no mapping file created)")
  end
  print("0) Exit")
  io.write("\nSelect an option: ")
end

while true do
  showMenu()
  local choice = io.read():match("%d")
  if choice == "1" then
    -- Launch the editor
    clearScreen()
    print("Launching Mapping Editor...\n")
    os.execute(editor_script)
    pause()
  elseif choice == "2" then
    clearScreen()
    print("Launching Machine Array Display...\n")
    os.execute(display_script)
    pause()
  elseif choice == "0" then
    clearScreen()
    print("Goodbye!")
    break
  else
    print("\nInvalid selection.")
    pause()
  end
end
  ]],

  machine_display = [[
local component    = require("component")
local term         = require("term")
local os           = require("os")
local fs           = require("filesystem")
local serialization= require("serialization")
local event        = require("event")
local keyboard     = require("keyboard")
local gpu          = component.gpu

-- === CONFIG ===
local mapping_file  = "/home/f_machine_mapping.lua"
local config_file   = "/home/f_config.lua"
local config        = {}
local updateInterval= 0.2
local barWidth      = 35
local columnWidth   = barWidth + 2
local startLine     = 3
local linesPerMachine = 3
gpu.setResolution(80, 25)
local screenW, screenH = gpu.getResolution()

-- === VARIABLES ===
local mapping = {}
local adapters   = {}

-- === HELPERS ===
local function drawProgressBar(x, y, width, active, current, max)
  local percent = (max > 0) and (current / max * 100) or 0
  local eta     = (max - current) / 20
  local fill    = math.floor((width - 5) * percent / 100)
  local empty   = width - 5 - fill
  local bar     = string.rep("█", fill) .. string.rep("░", empty)

  gpu.setForeground(active and 0x00FF00 or 0xAAAAAA)
  gpu.set(x, y, bar)
  gpu.setForeground(0xFFFFFF)
  gpu.set(x + width - 5, y, string.format(" %.1fs", eta))
end

local function sortByCoords()
  table.sort(adapters, function(a,b)
    if a.coords.x ~= b.coords.x then return a.coords.x < b.coords.x
    elseif a.coords.y ~= b.coords.y then return a.coords.y < b.coords.y
    else return a.coords.z < b.coords.z end
  end)
end

local function getName(address)
  for _, entry in ipairs(mapping) do
    if entry.address == address then
      return entry.name or "Unknown"
    end
  end
end

local function getCoords(address)
  for _, entry in ipairs(mapping) do
    if entry.address == address then
      return entry.coords or 0,0,0
    end
  end
end

local function getConfigValue(config, key)
  for _, entry in ipairs(config) do
    if entry.key == key then
      return entry.value
    end
  end
end

-- === LOADING ===

local function loadMapping()
  if not fs.exists(mapping_file) then
    return
  end
  local f = io.open(mapping_file, "r")
  local content = f:read("*a"); f:close()
  mapping = load("return "..content)()
  sortByCoords()
end


local function loadConfig()
  if not fs.exists(config_file) then
    return
  end
  local f = io.open(config_file, "r")
  local content = f:read("*a"); f:close()
  local loaded_config = load("return "..content)()

  config.title = getConfigValue(loaded_config, "title")
  config.update_interval = tonumber(getConfigValue(loaded_config, "update_interval"))
  config.adapter_type = getConfigValue(loaded_config, "adapter_type")
end

-- === WRAP MACHINES ===
local function wrapMachines()
  adapters = {}
  for address, _  in pairs(component.list(config.adapter_type)) do
    print(address)
    local proxy = component.proxy(address)
    table.insert(adapters, {
      name = getName(address),
      coords = getCoords(address),
      isMachineActive = function()
        return proxy.isMachineActive and proxy.isMachineActive() or false
      end,
      getWorkProgress   = proxy.getWorkProgress   and function() return proxy.getWorkProgress()   end,
      getWorkMaxProgress= proxy.getWorkMaxProgress and function() return proxy.getWorkMaxProgress() end
    })
  end
  sortByCoords()
end

-- === DRAW UI ===
local function drawUI()
  gpu.fill(1,1,screenW,screenH," ")
  local titleLine = string.format("== %s ==", config.title)
  gpu.set((screenW / 2) - (#titleLine / 2),1,titleLine)
  local leftLine, rightLine = startLine, startLine
  local rowsPerColumn     = math.floor((screenH-startLine)/linesPerMachine)

  for i, m in ipairs(adapters) do
    local active = m.isMachineActive()
    local cur    = m.getWorkProgress()
    local mx     = m.getWorkMaxProgress()
    local isLeft = i <= rowsPerColumn
    local x      = isLeft and 1 or (screenW - columnWidth +1)
    local y      = isLeft and leftLine or rightLine

    gpu.set(x, y, string.format("== %s ==", m.name))
    drawProgressBar(x, y+1, barWidth, active, cur, mx)

    if isLeft then leftLine  = leftLine  + linesPerMachine
    else          rightLine = rightLine + linesPerMachine end
  end
end

print("Loading Config")
loadConfig()
os.sleep(0.2)
print("Loading Mapping")
loadMapping()
os.sleep(0.2)
print("Loading Data")
wrapMachines()
os.sleep(0.2)
print("Starting...")

while true do
  local ev = { event.pull(config.update_interval, "key_down") }
  if ev[1] == "key_down" then
    local _, _, _, code = table.unpack(ev)
    if (code == keyboard.keys.w or code == keyboard.keys.q) and keyboard.isControlDown() then
      term.clear()
      os.exit()
    end
  end
  drawUI()
end

  ]],

  mapping_editor = [[
local fs         = require("filesystem")
local term       = require("term")
local event      = require("event")
local serialization = require("serialization")
local component  = require("component")
local gpu        = component.gpu
local keyboard   = require("keyboard")

-- === Config ===
local adapter_type = "gt_machine"
local mapping_file = "/home/f_machine_mapping.lua"
local config_file  = "/home/f_config.lua"

-- === State ===
local screenW, screenH = gpu.getResolution()
local selected        = 1
local hint            = ""
local mapping         = {}
local config          = {}

-- === Helpers ===

local function pause()
  io.write("\nPress Enter to continue...")
  io.read()
end

local function getTempValue(id)
  local sel = id or selected
  if sel <= #config then
    return config[sel].temp_value
  else 
    return mapping[sel - #config].temp_value
  end
end

local function setTempValue(tempValue, id)
  local sel = id or selected
  if sel <= #config then
    config[sel].temp_value = tempValue
  else 
    mapping[sel - #config].temp_value = tempValue
  end
end

local function getValue(id)
  local sel = id or selected
  if sel <= #config then
    return config[sel]
  else 
    return mapping[sel - #config]
  end
end

local function setValue(newValue, id)
  local sel = id or selected
  if sel <= #config then
    config[sel].value = value
  else 
    mapping[sel - #config].name = value
  end
end

local function sortByCoords()
  table.sort(mapping, function(a, b)
    if     a.coords.x ~= b.coords.x then return a.coords.x < b.coords.x
    elseif a.coords.y ~= b.coords.y then return a.coords.y < b.coords.y
    else   return a.coords.z < b.coords.z end
  end)
end

local function reloadFromAdapters()
  local found = {}
  for addr in component.list(adapter_type) do
    local proxy = component.proxy(addr)
    local existing
    for _, e in ipairs(mapping) do
      if e.address == addr then existing = e; break end
    end
    if existing then
      table.insert(found, existing)
    else
      local name   = proxy.getName       and proxy.getName()       or "unknown"
      local x,y,z       = proxy.getCoordinates and proxy.getCoordinates() or 0,0,0
      table.insert(found, {
        address = addr,
        name    = name,
        coords  = { x = x, y = y, z = z }
      })
    end
  end
  mapping = found
  sortByCoords()
end

local function createConfig() 
  config = {
    {key = "title", value = "GTNH Machine Monitor"},
    {key = "adapter_type", value = "gt_machine"},
    {key = "update_interval", value = 0.1}
  }
end

local function loadFiles()
  if fs.exists(mapping_file) then
    local f = io.open(mapping_file, "r")
    local content = f:read("*a"); f:close()
    mapping = load("return "..content)()
  else
    reloadFromAdapters()
    local f = io.open(mapping_file, "w")
    f:write(serialization.serialize(mapping))
    f:close()
  end
  sortByCoords()
  if selected > #mapping then selected = #mapping end

  if fs.exists(config_file) then
    local f = io.open(config_file, "r")
    local content = f:read("*a"); f:close()
    config = load("return "..content)()
  else 
    createConfig()
    local f = io.open(config_file, "w")
    f:write(serialization.serialize(config))
    f:close()
  end
end

local function saveFiles()
  local f = io.open(mapping_file, "w")
  for _, entry in ipairs(mapping) do
    if entry.temp_value and #entry.temp_value > 0 then
      entry.name = entry.temp_value
      entry.temp_value = nil
    end
  end

  for _, entry in ipairs(config) do
    if entry.temp_value and #entry.temp_value > 0 then
      entry.value = entry.temp_value
      entry.temp_value = nil
    end
  end
  f:write(serialization.serialize(mapping))
  f:close()

  local f = io.open(config_file, "w")
  f:write(serialization.serialize(config))
  f:close()
end

local function drawUI()
  term.clear()
  gpu.set(1,1,"== Machine Array Config == ")
  for i = 1, #config do
    local c = config[i]
    local mark = (i == selected) and ">" or " "
    local line = string.format("%s [%d] %s -- %s", mark, i, c.key, tostring(c.value))
    if getTempValue(i) ~= nil then
      line = line .. " -> " .. getTempValue(i)
    end

    gpu.set(1, i + 2, line:sub(1, screenW))
  end
    
  gpu.set(1, #config + 4,"== Machine Mapping Editor == ")
  local maxItems = screenH - 4
  for i = 1, math.min(#mapping, maxItems) do
    local id = i + #config
    local m    = mapping[i]
    local mark = (id == selected) and ">" or " "
    local name = m.name or ""
    local tail = string.format(" (%s) @ (%d,%d,%d)", m.address:sub(1,6), m.coords.x, m.coords.y, m.coords.z)
    local line = string.format("%s [%d] %s", mark, id, name) .. tail
    if getTempValue(id) ~= nil then
      line = line .. " -> " .. getTempValue(id)
    end

    gpu.set(1, i+5+#config, line:sub(1, screenW))
  end

  if hint ~= "" then
    gpu.set(1, screenH-1, hint:sub(1, screenW))
  end

  gpu.set(1, screenH, "[Ctrl+S] Save  [Ctrl+R] Reload Mapping  [Ctrl+W] Exit  [AnyKey] Edit Name")
end


-- === Event Handler ===
local function onKeyDown(char, code)
  if hint ~= "" then
    gpu.set(1, screenH, hint)
    hint = ""
  end

  if keyboard.isControlDown() then
    if code == keyboard.keys.s then       -- Ctrl+S
      saveFiles()
      hint = "Files saved."
    elseif code == keyboard.keys.r then   -- Ctrl+R
      reloadFromAdapters()
      hint = "Mapping reloaded."
    elseif code == keyboard.keys.w then
      term.clear()
      os.exit()
    end
  else
    if code == keyboard.keys.up then
      selected = selected - 1
      if selected == 0 then
        selected = #mapping + #config
      end
    elseif code == keyboard.keys.down then
      selected = selected + 1
      if selected > #mapping + #config then
        selected = 1
      end
    elseif code == 14 then
      local value = getTempValue()
      if value ~= nil and #value > 0 then
        if #value == 1 then
          setTempValue(nil)
        else
          setTempValue(value:sub(1, #value - 1))
        end
      end
    elseif char and char >= 32 and char <= 126 then
      setTempValue((getTempValue() or "") .. string.char(char))
    end
  end
end

local function handleEvent(eventType, ...)
  local arg = {...}

  if eventType == "key_down" then
    onKeyDown(arg[2], arg[3])
  end
  drawUI()
end

-- === Main ===
loadFiles()
drawUI()
while true do
  handleEvent(event.pull())
end
  ]],
}

-- === INSTALLER ===
term.clear()
print("== Installing GTNH Machine Monitor ==")

for name, code in pairs(scripts) do
  local path = "/home/" .. name .. ".lua"
  local f = io.open(path, "w")
  f:write(code)
  f:close()
  print("Installed: " .. path)
end

print("\nInstallation complete!")

os.execute("/home/launcher.lua")