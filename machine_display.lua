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
local startLine     = 3
local linesPerMachine = 3
gpu.setResolution(80, 25)
local screenW, screenH = gpu.getResolution()

-- === VARIABLES ===
local mapping = {}
local adapters   = {}

-- === HELPERS ===
local function drawProgressBar(x, y, width, active, current, max)
  current = tonumber(current) or 0
  max     = tonumber(max) or 0

  local percent = (max > 0) and (current / max * 100) or 0
  local eta = math.max(0, (max - current) / 20)
  local etaText = string.format("%4.1fs", eta)
  local usableWidth = math.max(1, width - #etaText - 1)
  local fill = math.floor(usableWidth * percent / 100)
  local empty = usableWidth - fill
  local bar = string.rep("█", fill) .. string.rep("░", empty)

  gpu.setForeground(active and 0x00FF00 or 0xAAAAAA)
  gpu.set(x, y, bar)

  gpu.setForeground(0xFFFFFF)
  gpu.set(x + usableWidth + 1, y, etaText)
end

local function sortByCoords()
  table.sort(adapters, function(a, b)
    local ac = a.coords or {}
    local bc = b.coords or {}

    local ax = tonumber(ac.x) or 0
    local ay = tonumber(ac.y) or 0
    local az = tonumber(ac.z) or 0

    local bx = tonumber(bc.x) or 0
    local by = tonumber(bc.y) or 0
    local bz = tonumber(bc.z) or 0

    if ax ~= bx then
      return ax < bx
    elseif ay ~= by then
      return ay < by
    else
      return az < bz
    end
  end)
end

local function getName(address)
  for _, entry in ipairs(mapping) do
    if entry.address == address then
      return entry.name or "Unknown"
    end
  end

  return "Unknown"
end

local function getCoords(address)
  for _, entry in ipairs(mapping) do
    if entry.address == address then
      return entry.coords or {x = 0, y = 0, z = 0}
    end
  end

  return {x = 0, y = 0, z = 0}
end

local function getConfigValue(config, key)
  for _, entry in ipairs(config) do
    if entry.key == key then
      return entry.value
    end
  end
end

local function componentExists(address)
  return component.get(address) ~= nil
end

-- === LOADING ===

local function loadMapping()
  if not fs.exists(mapping_file) then
    return
  end
  local f = io.open(mapping_file, "r")
  local content = f:read("*a"); f:close()
  mapping = load("return "..content)()
  local fn, err = load("return " .. content)

  if not fn then
    print("Mapping parse error: " .. tostring(err))
    return
  end

  local ok
  ok, mapping = pcall(fn)

  if not ok or type(mapping) ~= "table" then
    print("Invalid config file")
    return
  end
  sortByCoords()
end


local function loadConfig()
  if not fs.exists(config_file) then
    return
  end
  local f = io.open(config_file, "r")
  local content = f:read("*a"); f:close()
  local fn, err = load("return " .. content)

  if not fn then
    print("Config parse error: " .. tostring(err))
    return
  end

  local ok, loaded_config = pcall(fn)

  if not ok or type(loaded_config) ~= "table" then
    print("Invalid config file")
    return
  end

  config.title = getConfigValue(loaded_config, "title")
  config.update_interval = tonumber(getConfigValue(loaded_config, "update_interval"))
  config.adapter_type = getConfigValue(loaded_config, "adapter_type")
end

-- === WRAP MACHINES ===
local function wrapMachines()
  adapters = {}

  for _, entry in ipairs(mapping) do
    local address = entry.address

    if address and componentExists(address) then
      local ok, proxy = pcall(component.proxy, address)

      if ok and proxy then
        table.insert(adapters, {
          address = address,
          name = entry.name or "Unknown",
          coords = entry.coords or {x=0,y=0,z=0},

          isMachineActive = function()
            local ok1, result = pcall(function()
              return proxy.isMachineActive and proxy.isMachineActive()
            end)
            return ok1 and result or false
          end,

          getWorkProgress = function()
            local ok1, result = pcall(function()
              return proxy.getWorkProgress and proxy.getWorkProgress()
            end)
            return ok1 and result or 0
          end,

          getWorkMaxProgress = function()
            local ok1, result = pcall(function()
              return proxy.getWorkMaxProgress and proxy.getWorkMaxProgress()
            end)
            return ok1 and result or 0
          end
        })
      end
    end
  end

  sortByCoords()
end

-- === DRAW UI ===
local function drawUI()
  gpu.fill(1,1,screenW,screenH," ")
  local titleLine = string.format("== %s ==", config.title)
  gpu.set((screenW / 2) - (#titleLine / 2),1,titleLine)

  local rowsPerColumn = math.max(1, math.floor((screenH - startLine) / linesPerMachine))
  local columnCount = math.max(1,math.ceil(#adapters / rowsPerColumn))
  local columnWidth = math.floor(screenW / columnCount)
  local barWidth = math.max(10, columnWidth - 2)

  for i, m in ipairs(adapters) do
    local active = m.isMachineActive
    local cur = m.getWorkProgress
    local mx = m.getWorkMaxProgress

    local row = ((i - 1) % rowsPerColumn)
    local column = math.floor((i - 1) / rowsPerColumn)
    local x = 1 + column * columnWidth
    local y = startLine + row * linesPerMachine

    gpu.set(x, y, string.sub(m.name,1,columnWidth-1))

    drawProgressBar(
        x,
        y + 1,
        barWidth,
        active,
        cur,
        mx
    )
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
