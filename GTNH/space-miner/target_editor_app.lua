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

local requestPort = config.ports.telemetry
local replyPort = config.ports.targetEditor or config.ports.command
modem.setStrength(400)
modem.open(replyPort)
assert(modem.isOpen(replyPort),
       "Could not open target-editor reply port " .. tostring(replyPort))

local brokerAddress = nil
local requestSequence = 0

local function nextRequestId()
  requestSequence = requestSequence + 1
  return string.format("%s:%.3f:%d",
    computer.address():sub(1, 8), computer.uptime(), requestSequence)
end

local function exchange(payloadType, settings, showProgress)
  local requestId = nextRequestId()
  local packet = serialization.serialize({
    protocol = "MEDINA_TARGET_EDITOR",
    payloadType = payloadType,
    requestId = requestId,
    replyPort = replyPort,
    settings = settings,
  })

  if #packet > modem.maxPacketSize() then
    return false, "Target configuration is too large for one modem packet (" ..
                  #packet .. "/" .. modem.maxPacketSize() .. " bytes)"
  end

  local function transmit()
    if brokerAddress then
      return modem.send(brokerAddress, requestPort, packet)
    end
    return modem.broadcast(requestPort, packet)
  end

  local deadline = computer.uptime() + 10
  local nextSend = 0
  local attempts = 0
  while computer.uptime() < deadline do
    local now = computer.uptime()
    if now >= nextSend then
      attempts = attempts + 1
      local ok, sent = pcall(transmit)
      if not ok or not sent then
        return false, "Could not send target-editor packet on port " ..
                      requestPort .. ": " ..
                      tostring(ok and "modem returned false" or sent)
      end
      if showProgress then
        io.write(string.format("\rDiscovery request %d on port %d...",
                              attempts, requestPort))
      end
      nextSend = now + 1
    end

    local remaining = deadline - computer.uptime()
    local untilRetry = math.max(0, nextSend - computer.uptime())
    local ev = {
      event.pull(math.min(0.25, remaining, untilRetry), "modem_message")
    }
    if ev[1] == "modem_message" and ev[4] == replyPort then
      local decoded, response = pcall(serialization.unserialize, ev[6])
      if decoded and type(response) == "table" and
         response.protocol == "MEDINA_TARGET_EDITOR" and
         response.payloadType == "TARGET_CONFIG_RESULT" and
         response.requestId == requestId then
        brokerAddress = ev[3]
        if showProgress then print("") end
        return response.success == true, response.message, response.settings
      end
    end
  end

  if showProgress then print("") end
  return false, "Broker did not answer requests on port " .. requestPort ..
                " using reply port " .. replyPort .. " after " ..
                attempts .. " attempts"
end

term.clear()
gpu.setForeground(0x00FFFF)
print("Connecting to MEDINA broker...")
print("Local modem: " .. tostring(modem.address or "unknown"))
print("Request port: " .. requestPort .. "  Reply port: " .. replyPort)
gpu.setForeground(0xFFFFFF)

local connected, connectMessage, brokerSettings =
  exchange("TARGET_CONFIG_REQUEST", nil, true)
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
