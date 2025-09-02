local component    = require("component")
local term         = require("term")
local os           = require("os")
local fs           = require("filesystem")
local serialization= require("serialization")
local event        = require("event")
local keyboard     = require("keyboard")
local gpu          = component.gpu

-- === CONFIG ===
local base_path     = "/home/gtnh_monitor/"
local mapping_file  = base_path .. "f_machine_mapping.lua"
local config_file   = base_path .. "f_config.lua"
local config        = {}
local updateInterval= 0.2
local barWidth      = 35
local columnWidth   = barWidth + 2
local startLine     = 3
local linesPerMachine = 3
--gpu.setResolution(80, 25)
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
