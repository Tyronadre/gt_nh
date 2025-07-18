local component    = require("component")
local term         = require("term")
local os           = require("os")
local fs           = require("filesystem")
local serialization= require("serialization")
local event        = require("event")
local keyboard     = require("keyboard")
local gpu          = component.gpu

-- === CONFIG ===
local title         = "== GTNH Machine Monitor =="
local adapter_type  = "gt_machine"
local mapping_file  = "/home/f_machine_mapping.lua"
local updateInterval= 0.2
local barWidth      = 35
local columnWidth   = barWidth + 2
local startLine     = 3
local linesPerMachine = 3

gpu.setResolution(80, 25)
local screenW, screenH = gpu.getResolution()

-- === VARIABLES ===
local machineMap = {}
local adapters   = {}

-- === DRAW HELPERS ===
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

-- === MAPPING LOADING ===
local function sortByCoords()
  table.sort(machineMap, function(a,b)
    if a.coords.x ~= b.coords.x then return a.coords.x < b.coords.x
    elseif a.coords.y ~= b.coords.y then return a.coords.y < b.coords.y
    else return a.coords.z < b.coords.z end
  end)
end

local function loadMapping()
  if not fs.exists(mapping_file) then
    term.clear()
    error("Mapping file not found. Create machine_mapping.lua first.")
  end
  local f = io.open(mapping_file, "r")
  local content = f:read("*a"); f:close()
  machineMap = load("return "..content)()
  sortByCoords()
end

-- === WRAP MACHINES ===
local function wrapMachines()
  adapters = {}
  for _, entry in ipairs(machineMap) do
    local proxy = component.proxy(entry.address)
    table.insert(adapters, {
      name = entry.name,
      isMachineActive = function()
        return proxy.isMachineActive and proxy.isMachineActive() or false
      end,
      getWorkProgress   = proxy.getWorkProgress   and function() return proxy.getWorkProgress()   end,
      getWorkMaxProgress= proxy.getWorkMaxProgress and function() return proxy.getWorkMaxProgress() end
    })
  end
end

-- === DRAW UI ===
local function drawUI()
  gpu.fill(1,1,screenW,screenH," ")
  gpu.set(1,1,title)
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

loadMapping()
wrapMachines()

while true do
  local ev = { event.pull(updateInterval, "key_down") }
  if ev[1] == "key_down" then
    local _, _, _, code = table.unpack(ev)
    if (code == keyboard.keys.w or code == keyboard.keys.q) and keyboard.isControlDown() then
      term.clear()
      os.exit()
    end
  end
  drawUI()
end
