local fs         = require("filesystem")
local term       = require("term")
local event      = require("event")
local serialization = require("serialization")
local component  = require("component")
local gpu        = component.gpu
local keyboard   = require("keyboard")

-- === Config ===
local adapter_type = "gt_machine"
local mapping_file = "/home/machine_mapping.lua"

-- === State ===
local screenW, screenH = gpu.getResolution()
local selected        = 1
local hint            = ""
local mapping         = {}

-- === Helpers ===
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

local function loadMapping()
  if fs.exists(mapping_file) == true then
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
end

local function saveMapping()
  local f = io.open(mapping_file, "w")
  for _, entry in ipairs(mapping) do
    if entry.new_name and #entry.new_name > 0 then
      entry.name = entry.new_name
      entry.new_name = nil
    end
  end
  print(serialization.serialize(mapping))
  f:write(serialization.serialize(mapping))
  f:close()
end

local function drawUI()
  term.clear()
  gpu.set(1,1,"== Machine Mapping Editor == ")
  local maxItems = screenH - 4
  for i = 1, math.min(#mapping, maxItems) do
    local m    = mapping[i]
    local mark = (i == selected) and ">" or " "
    local name = m.name or ""
    local tail = string.format(" (%s) @ (%d,%d,%d)", m.address:sub(1,6), m.coords.x, m.coords.y, m.coords.z)
    local line = string.format("%s [%d] %s", mark, i, name) .. tail
    if mapping[i].new_name ~= nil then
      line = line .. " -> " .. mapping[i].new_name
    end

    gpu.set(1, i+2, line:sub(1, screenW))
  end

  if hint ~= "" then
    gpu.set(1, screenH-1, hint:sub(1, screenW))
  end

  gpu.set(1, screenH, "[Ctrl+S] Save  [Ctrl+R] Reload  [Ctrl+D] Delete  [Ctrl+Q] Quit")
end

local function deleteEntry(idx)
  table.remove(mapping, idx)
  if selected > #mapping then selected = #mapping end
end

-- === Event Handler ===
local function onKeyDown(char, code)
  if hint ~= "" then
    gpu.set(1, screenH, hint)
    hint = ""
  end

  if keyboard.isControlDown() then
    if code == keyboard.keys.s then       -- Ctrl+S
      saveMapping()
      hint = "Mapping saved."
    elseif code == keyboard.keys.r then   -- Ctrl+R
      reloadFromAdapters()
      hint = "Mapping reloaded."
    elseif code == keyboard.keys.d then   -- Ctrl+D
      deleteEntry(selected)
      hint = "Entry deleted."
    elseif code == keyboard.keys.q then
      term.clear()
      os.exit()
    end
  else
    if code == keyboard.keys.up then
      selected = math.max(1, selected - 1)
    elseif code == keyboard.keys.down then
      selected = math.min(#mapping, selected + 1)
    elseif code == 14 then
      local name = mapping[selected].new_name
      if name ~= nil and #name > 0 then
        if #name == 1 then
          mapping[selected].new_name = nil
        else
          mapping[selected].new_name = name:sub(1, #name - 1)
        end
      end
    elseif char and char >= 32 and char <= 126 then
      mapping[selected].new_name = (mapping[selected].new_name or "") .. string.char(char)
    end
    end
end

local function handleEvent(eventType, ...)
  local arg = {...}

  if eventType == "key_down" then
    onKeyDown(arg[2], arg[3])
  elseif eventType == "touch" then
    -- Handle touch events if needed
  end
  drawUI()
end

-- === Main ===
loadMapping()
drawUI()
while true do
  handleEvent(event.pull())
end
