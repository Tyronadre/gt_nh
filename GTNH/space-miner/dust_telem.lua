-- =============================================================================
-- Node ID: MEDINA-DustRelay
-- File:    dust_telem.lua
-- Purpose: Queries the dust storage ME subnet; displays the 10 most critical
--          configured items and broadcasts every known mineable item to the
--          broker. Press T to switch exclusively into the stock-target editor.
--
-- OpenComputers Sides Reference Matrix:
--   0 = Bottom / Down (-Y) | 1 = Top / Up (+Y) | 2 = North (-Z)
--   3 = South (+Z)         | 4 = West (-X)     | 5 = East (+X)
-- =============================================================================

local component     = require("component")
local computer      = require("computer")
local event         = require("event")
local keyboard      = require("keyboard")
local serialization = require("serialization")
local term          = require("term")

local config = dofile("/home/config.lua")
local editorModule = dofile("/home/target_editor.lua")

if not component.isAvailable("modem")   then error("Missing network card.")          end
if not component.isAvailable("me_controller") then error("Missing ME Controller.") end
if not component.isAvailable("gpu")            then error("Requires GPU.")           end

local modem = component.modem
if not modem.isWireless or not modem.isWireless() then
  error("Node requires a T2 Wireless Network Card.")
end

local me_ctrl  = component.me_controller
local gpu      = component.gpu
local nodeName = "MEDINA-DustRelay"

modem.setStrength(400)
gpu.setResolution(80, 25)

local thresholds = {}
local targetSettingsRevision
local function revisionOf(settings)
  local text = serialization.serialize(settings)
  local hash = 0
  for index = 1, #text do
    hash = (hash * 31 + text:byte(index)) % 2147483647
  end
  return tostring(#text) .. ":" .. tostring(hash)
end

local function refreshThresholds()
  thresholds = {}
  for _, cond in ipairs(config.conditions) do
    thresholds[cond.itemName] = cond.amountToMaintain
  end
  targetSettingsRevision = revisionOf(config.targetSettings)
end
refreshThresholds()

-- Scan every registered target, not just the locally configured targets. The
-- broker can then enable a previously disabled item from its runtime editor.
local trackedItems = {}
for itemName in pairs(config.dustTargets) do
  trackedItems[itemName] = true
end

local function scanDustStock()
  local stocks = {}
  local success, items = pcall(me_ctrl.getItemsInNetwork)
  if success and items then
    for _, item in ipairs(items) do
      if item and item.label and trackedItems[item.label] then
        stocks[item.label] = (stocks[item.label] or 0) + item.size
      end
    end
  end
  return stocks
end

local function buildSortedList(stocks)
  local list = {}
  for name, threshold in pairs(thresholds) do
    local stock = stocks[name] or 0
    table.insert(list, { name=name, stock=stock, threshold=threshold, ratio=stock/threshold })
  end
  table.sort(list, function(a, b) return a.ratio < b.ratio end)
  return list
end

local function drawStaticFrame()
  term.clear()
  gpu.setForeground(0x00FF00)
  print("================================================================================")
  print(" MEDINA RELAY NETWORK  |  NODE: " .. nodeName)
  print("================================================================================")
  gpu.setForeground(0x888888)
  term.setCursor(2, 4)
  io.write("[T] EDIT STOCK TARGETS  (telemetry pauses only while editor is open)")
  term.setCursor(2, 5)
  io.write(string.format("  %-29s  %20s  %s", "ITEM (lowest fill first)", "STOCK / TARGET", "FILL"))
  term.setCursor(2, 6)
  io.write(string.rep("-", 76))
end

local function formatQty(n)
  if n >= 1000000 then return string.format("%.1fm", n / 1000000)
  elseif n >= 1000 then return string.format("%.0fk", n / 1000)
  else return tostring(n) end
end

local function updateDashboard(sorted)
  -- Display top 10 most critical items (rows 7-16)
  for i = 1, 10 do
    local row = 6 + i
    term.setCursor(2, row)
    gpu.fill(2, row, 76, 1, " ")
    local item = sorted[i]
    if item then
      local pct = item.ratio > 0 and math.floor(item.ratio * 100) or 0
      local color
      if pct < 25      then color = 0xFF4444
      elseif pct < 75  then color = 0xFFAA00
      else                 color = 0x00FFFF
      end
      gpu.setForeground(color)
      -- Right-align stock/target in 20-char field
      local stockTarget = string.format("%10s / %8s", formatQty(item.stock), formatQty(item.threshold))
      local line = string.format("  %-29s  %20s  %3d%%",
        item.name, stockTarget, pct)
      io.write(line)
    end
  end
  gpu.setForeground(0x555555)
  term.setCursor(55, 2)
  io.write("LAST_SYNC: " .. os.date("%X"))
end

local trackedNames = {}
for itemName in pairs(trackedItems) do trackedNames[#trackedNames+1] = itemName end
table.sort(trackedNames)

-- The first chunk also carries target_config, so leave generous packet room.
local CHUNK_SIZE = 10
local chunkCount = math.ceil(#trackedNames / CHUNK_SIZE)
local batchId = 0

local function broadcastPacket(message)
  local packet = serialization.serialize(message)
  if #packet > modem.maxPacketSize() then
    return false, "packet too large: " .. #packet .. "/" ..
                  modem.maxPacketSize() .. " bytes"
  end

  local ok, sent = pcall(modem.broadcast, config.ports.telemetry, packet)
  if not ok then return false, tostring(sent) end
  if not sent then return false, "modem.broadcast returned false" end
  return true
end

local function drawTargetSyncStatus(ok, message)
  local row = 18
  gpu.fill(2, row, 76, 1, " ")
  term.setCursor(2, row)
  if ok then
    gpu.setForeground(0x00AA00)
    io.write(("TARGET CONFIG " .. targetSettingsRevision ..
              ": embedded in dust snapshot"):sub(1, 76))
  else
    gpu.setForeground(0xFF4444)
    io.write(("TARGET CONFIG ERROR: " .. tostring(message)):sub(1, 76))
  end
end

local function telemetryUpdate()
  local stocks = scanDustStock()
  local sorted = buildSortedList(stocks)
  updateDashboard(sorted)

  batchId = batchId + 1
  local targetChunkSent = false
  local targetChunkError = nil
  for chunkIndex = 1, chunkCount do
    local payload = {}
    local first = (chunkIndex - 1) * CHUNK_SIZE + 1
    local last = math.min(#trackedNames, first + CHUNK_SIZE - 1)
    for index = first, last do
      local name = trackedNames[index]
      payload[name] = {
        stock = stocks[name] or 0,
        threshold = thresholds[name] or 0,
      }
    end

    local message = {
      protocol    = "MEDINA_TELEMETRY",
      sender      = nodeName,
      payloadType = "DUST_UPDATE",
      batchId     = batchId,
      chunkIndex  = chunkIndex,
      chunkCount  = chunkCount,
      data        = payload,
    }
    if chunkIndex == 1 then
      message.targetRevision = targetSettingsRevision
      message.targetSettings = config.targetSettings
    end

    local sent, sendError = broadcastPacket(message)
    if chunkIndex == 1 then
      targetChunkSent = sent
      targetChunkError = sendError
    end
  end
  drawTargetSyncStatus(targetChunkSent, targetChunkError)
end

local targetEditor = editorModule.create({
  gpu = gpu,
  term = term,
  keyboard = keyboard,
  computer = computer,
  config = config,
  path = "/home/target_config.lua",
  validate = config.buildTargetConditions,
  persist = function(settings)
    local written, writeError =
      editorModule.writeSettings("/home/target_config.lua", settings)
    if not written then return false, writeError end
    return true, "Saved locally. Close editor to publish with dust telemetry."
  end,
  apply = function(settings)
    config.applyTargetSettings(settings)
    refreshThresholds()
  end,
  headerText = "MEDINA TARGET EDITOR - DUST TELEMETRY PAUSED",
  openHint = "Telemetry is paused. Save, then Esc to publish and resume.",
})

local function runEditorMode()
  targetEditor:open()
  targetEditor:draw()

  while targetEditor:isOpen() do
    local ev = { event.pull(0.05) }
    local renderMode = nil

    if ev[1] == "interrupted" then
      return false
    elseif ev[1] == "key_down" then
      renderMode = targetEditor:handleKey(ev[3], ev[4])
    elseif ev[1] == "key_up" then
      targetEditor:handleKeyUp(ev[4])
    elseif ev[1] == "touch" then
      renderMode = targetEditor:handleTouch(ev[3], ev[4])
    elseif not ev[1] and targetEditor:isEditing() then
      renderMode = "input"
    end

    if targetEditor:isOpen() then
      if renderMode == "full" then
        targetEditor:draw()
      elseif renderMode == "input" then
        targetEditor:drawFast()
      end
    end
  end

  return true
end

local function runTelemetryMode()
  drawStaticFrame()
  local nextUpdate = 0

  while true do
    local now = computer.uptime()
    if now >= nextUpdate then
      telemetryUpdate()
      nextUpdate = computer.uptime() + 10
    end

    local timeout = math.min(0.1, math.max(0, nextUpdate - computer.uptime()))
    local ev = { event.pull(timeout) }
    if ev[1] == "interrupted" then
      return false
    elseif ev[1] == "key_down" and
           (ev[4] == keyboard.keys.t or ev[4] == keyboard.keys.f4) then
      return true
    end
  end
end

-- Exactly one of these loops runs at a time. ME scans and telemetry broadcasts
-- stop completely while the editor owns the keyboard and screen.
while true do
  if not runTelemetryMode() then break end
  if not runEditorMode() then break end
end

gpu.setBackground(0x000000)
gpu.setForeground(0xFFFFFF)
term.clear()
print("MEDINA dust telemetry stopped.")
