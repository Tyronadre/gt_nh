local fs         = require("filesystem")
local term       = require("term")
local event      = require("event")
local serialization = require("serialization")
local component  = require("component")
local gpu        = component.gpu
local keyboard   = require("keyboard")

-- === Config ===
local default_adapter_type = "gt_machine"
local base_path    = "/home/gtnh_monitor/"
local mapping_file = base_path .. "f_machine_mapping.lua"
local config_file  = base_path .. "f_config.lua"

-- === State ===
local screenW, screenH = gpu.getResolution()
local selected        = 1
local scrollOffset    = 0
local hint            = ""
local mapping         = {}
local config          = {}

-- === Helpers ===
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
    return config[sel].value
  else 
    return mapping[sel - #config].value
  end
end

local function setValue(newValue, id)
  local sel = id or selected
  if sel <= #config then
    config[sel].value = newValue
  else 
    mapping[sel - #config].name = newValue
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
  local adapter_type = getValue(2)
  if not adapter_type then adapter_type = default_adapter_type end
  for addr in component.list(adapter_type) do
    local proxy = component.proxy(addr)
    local existing
    for _, e in ipairs(mapping) do
      if e.address == addr then existing = e; break end
    end
    if existing then
      table.insert(found, existing)
    else
      local name   = proxy.getName and proxy.getName() or "unknown"
      local x,y,z  = proxy.getCoordinates()
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
end

local function saveFiles()
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

  local f = io.open(mapping_file, "w")
  f:write(serialization.serialize(mapping))
  f:close()

  local f2 = io.open(config_file, "w")
  f2:write(serialization.serialize(config))
  f2:close()
end

-- === Drawing ===

local function drawId(y, idText, isSelected)
  local oldFg = gpu.getForeground()
  local oldBg = gpu.getBackground()
  if isSelected then
    gpu.setForeground(oldBg)
    gpu.setBackground(oldFg)
  end
  gpu.set(1, y, idText)
  if isSelected then
    gpu.setForeground(oldFg)
    gpu.setBackground(oldBg)
  end
end

local function drawLine(y, id, text, isSelected)
  local idText = string.format("[%d]", id)
  drawId(y, idText, isSelected)
  gpu.set(#idText + 2, y, text:sub(1, screenW))
end


local function drawUI()
  term.clear()
  gpu.set(1,1,"== Machine Array Config ==")

  for i = 1, #config do
    local c = config[i]
    local line = string.format("%s -- %s", c.key, tostring(c.value))
    if getTempValue(i) then
      line = line .. " -> " .. getTempValue(i)
    end
    drawLine(i+2, i, line, (i == selected))
  end

  gpu.set(1, #config + 4,"== Machine Mapping Editor ==")
  local maxItems = screenH - (#config + 6)
  if selected > #config + scrollOffset + maxItems then
    scrollOffset = selected - #config - maxItems
  elseif selected <= #config + scrollOffset then
    scrollOffset = selected - #config - 1
    if scrollOffset < 0 then scrollOffset = 0 end
  end

  for i = 1, math.min(#mapping - scrollOffset, maxItems) do
    local id = i + #config + scrollOffset
    local m = mapping[i+scrollOffset]
    local line = string.format("%s (%s) @ (%d,%d,%d)", m.name or "", m.address:sub(1,6), m.coords.x, m.coords.y, m.coords.z)
    if getTempValue(id) then
      line = line .. " -> " .. getTempValue(id)
    end
    drawLine(i + #config + 5, id, line, (id == selected))
  end

  if hint ~= "" then
    gpu.set(1, screenH-1, hint:sub(1, screenW))
  end
  gpu.set(1, screenH, "[Ctrl+S] Save  [Ctrl+R] Reload  [Ctrl+W] Exit")
end

-- === Event Handlers ===
local function onKeyDown(char, code)
  if keyboard.isControlDown() then
    if code == keyboard.keys.s then saveFiles(); hint = "Files saved."
    elseif code == keyboard.keys.r then reloadFromAdapters(); hint = "Mapping reloaded."
    elseif code == keyboard.keys.w then term.clear(); os.exit()
    end
  else
    if code == keyboard.keys.up then
      selected = (selected-2)%(#mapping+#config)+1
    elseif code == keyboard.keys.down then
      selected = (selected)%(#mapping+#config)+1
    elseif code == keyboard.keys.back then
      local v = getTempValue() or ""
      setTempValue(#v>0 and v:sub(1,#v-1) or nil)
    elseif char and char>=32 and char<=126 then
      setTempValue((getTempValue() or "")..string.char(char))
    end
  end
end

local function onTouch(x, y)
  if y >= 3 and y <= 2+#config then
    selected = y-2
  elseif y >= #config+6 and y <= screenH-2 then
    local idx = y - (#config+5) + scrollOffset
    if idx >=1 and idx <= #mapping then
      selected = #config + idx
    end
  end
end

local function handleEvent(eventType, ...)
  local arg = {...}
  if eventType == "key_down" then
    onKeyDown(arg[2], arg[3])
  elseif eventType == "touch" then
    onTouch(arg[2], arg[3])
  end
  drawUI()
end

-- === Main ===
loadFiles()
drawUI()
while true do
  handleEvent(event.pull())
end
