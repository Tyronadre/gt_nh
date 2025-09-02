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
local mapping_file = base_path + "f_machine_mapping.lua"
local config_file  = base_path + "f_config.lua"

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
    return config[sel].value
  else 
    return mapping[sel - #config].value
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
      hint = "Mapping reloaded. "
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
