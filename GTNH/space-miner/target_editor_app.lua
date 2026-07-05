-- =============================================================================
-- MEDINA REMOTE TARGET EDITOR
--
-- Run this on a separate OpenComputers computer with:
--   T2 wireless card, GPU, screen, keyboard, config.lua, target_config.lua,
--   target_editor.lua, and this file.
--
-- The editor has its own event loop and therefore cannot be delayed by mining
-- module hardware calls. Ctrl+S sends the complete validated configuration to
-- the running broker, which saves and applies it.
-- =============================================================================

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local keyboard      = require("keyboard")
local serialization = require("serialization")
local term          = require("term")

local config = dofile("/home/config.lua")
local editorModule = dofile("/home/target_editor.lua")

assert(component.isAvailable("modem"), "Missing network card.")
assert(component.isAvailable("gpu"), "Missing GPU.")

local modem = component.modem
assert(modem.isWireless and modem.isWireless(),
       "Target editor requires a T2 wireless network card.")

local gpu = component.gpu
local width, height = gpu.maxResolution()
gpu.setResolution(width, height)

local port = config.ports.command
modem.setStrength(400)
modem.open(port)

local brokerAddress = nil
local requestSequence = 0

local function nextRequestId()
  requestSequence = requestSequence + 1
  return string.format("%s:%.3f:%d",
    computer.address():sub(1, 8), computer.uptime(), requestSequence)
end

local function exchange(payloadType, settings)
  local requestId = nextRequestId()
  local packet = serialization.serialize({
    protocol = "MEDINA_TARGET_EDITOR",
    payloadType = payloadType,
    requestId = requestId,
    settings = settings,
  })

  local sent
  if brokerAddress then
    sent = modem.send(brokerAddress, port, packet)
  else
    sent = modem.broadcast(port, packet)
  end
  if not sent then
    return false, "Could not send target-editor packet on port " .. port
  end

  local deadline = computer.uptime() + 10
  while computer.uptime() < deadline do
    local remaining = deadline - computer.uptime()
    local ev = { event.pull(math.min(0.25, remaining), "modem_message") }
    if ev[1] == "modem_message" and ev[4] == port then
      local decoded, response = pcall(serialization.unserialize, ev[6])
      if decoded and type(response) == "table" and
         response.protocol == "MEDINA_TARGET_EDITOR" and
         response.payloadType == "TARGET_CONFIG_RESULT" and
         response.requestId == requestId then
        brokerAddress = ev[3]
        return response.success == true, response.message, response.settings
      end
    end
  end

  return false, "Broker did not answer on port " .. port
end

term.clear()
gpu.setForeground(0x00FFFF)
print("Connecting to MEDINA broker...")
gpu.setForeground(0xFFFFFF)

local connected, connectMessage, brokerSettings =
  exchange("TARGET_CONFIG_REQUEST")
if not connected or type(brokerSettings) ~= "table" then
  error("Target editor connection failed: " .. tostring(connectMessage), 0)
end

config.applyTargetSettings(brokerSettings)

local function persistRemotely(settings)
  local applied, message, returnedSettings =
    exchange("TARGET_CONFIG_APPLY", settings)
  if not applied then return false, message end

  local cacheSettings = type(returnedSettings) == "table" and
                        returnedSettings or settings
  local cached, cacheError = editorModule.writeSettings(
    "/home/target_config.lua", cacheSettings)
  if not cached then
    return true, tostring(message) .. " (local cache failed: " ..
                 tostring(cacheError) .. ")"
  end
  return true, tostring(message)
end

local targetEditor = editorModule.create({
  gpu = gpu,
  term = term,
  keyboard = keyboard,
  computer = computer,
  config = config,
  path = "/home/target_config.lua",
  validate = config.buildTargetConditions,
  persist = persistRemotely,
  reload = function()
    local received, message, settings = exchange("TARGET_CONFIG_REQUEST")
    if not received or type(settings) ~= "table" then
      error(message or "Broker returned no target settings", 0)
    end
    return settings
  end,
  apply = function(settings)
    config.applyTargetSettings(settings)
  end,
})

targetEditor:open()
targetEditor:draw()

while targetEditor:isOpen() do
  local ev = { event.pull(0.05) }
  local renderMode = nil

  if ev[1] == "interrupted" then
    break
  elseif ev[1] == "key_down" then
    renderMode = targetEditor:handleKey(ev[3], ev[4])
  elseif ev[1] == "key_up" then
    targetEditor:handleKeyUp(ev[4])
  elseif ev[1] == "touch" then
    renderMode = targetEditor:handleTouch(ev[3], ev[4])
  elseif not ev[1] and targetEditor:isEditing() then
    renderMode = "input" -- cursor blink
  end

  if targetEditor:isOpen() then
    if renderMode == "full" then
      targetEditor:draw()
    elseif renderMode == "input" then
      targetEditor:drawFast()
    end
  end
end

gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
print("MEDINA target editor closed.")
