-- =============================================================================
-- MEDINA TARGET EDITOR
-- Structured, non-blocking editor for /home/target_config.lua.
--
-- The broker owns the event loop and calls handleEvent()/draw(). This keeps
-- telemetry, module lifecycle, and scheduler tasks running while the editor is
-- open. Text fields use an explicit blinking block cursor so the insertion
-- position remains visible on OpenComputers screens.
-- =============================================================================

local filesystem    = require("filesystem")
local serialization = require("serialization")

local editorModule = {}

local ESC_KEY = 0x01
local GLOBAL_ROWS = 5

local function clone(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, entry in pairs(value) do
    result[clone(key, seen)] = clone(entry, seen)
  end
  return result
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function parseQty(value)
  if type(value) == "number" then return value end
  local normalized = string.lower((tostring(value):gsub("%s+", ""):gsub(",", ".")))
  local number, suffix = normalized:match("^(%d+%.?%d*)([kmbt]?)$")
  if not number then return tonumber(normalized) end
  local multipliers = { k=1000, m=1000000, b=1000000000, t=1000000000000 }
  return tonumber(number) * (multipliers[suffix] or 1)
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do keys[#keys+1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function serializeTargetConfig(settings)
  local lines = {
    "-- target_config.lua",
    "-- Managed by MEDINA's runtime target editor. A backup is kept as",
    "-- target_config.lua.bak whenever the editor saves this file.",
    "",
    "local targets = {}",
    "",
    "targets.currentCellType = " .. serialization.serialize(settings.currentCellType),
    "targets.cellCount = " .. serialization.serialize(settings.cellCount),
    "targets.safetyMargin = " .. serialization.serialize(settings.safetyMargin),
    "targets.maxTargetOverride = " .. serialization.serialize(settings.maxTargetOverride or 0),
    "targets.keepAllMinedItems = " ..
      serialization.serialize(settings.keepAllMinedItems == true),
    "",
    "targets.CELL_CAPACITIES = {",
  }

  for _, cellType in ipairs(sortedKeys(settings.CELL_CAPACITIES)) do
    lines[#lines+1] = "  [" .. serialization.serialize(cellType) .. "] = " ..
                      serialization.serialize(settings.CELL_CAPACITIES[cellType]) .. ","
  end

  lines[#lines+1] = "}"
  lines[#lines+1] = ""
  lines[#lines+1] = "targets.items = {"

  for _, itemName in ipairs(sortedKeys(settings.items)) do
    lines[#lines+1] = "  [" .. serialization.serialize(itemName) .. "] = " ..
                      serialization.serialize(settings.items[itemName]) .. ","
  end

  lines[#lines+1] = "}"
  lines[#lines+1] = ""
  lines[#lines+1] = "return targets"
  lines[#lines+1] = ""
  return table.concat(lines, "\n")
end

local function writeAtomic(path, content)
  local tempPath = path .. ".tmp"
  local backupPath = path .. ".bak"

  local file, openError = io.open(tempPath, "w")
  if not file then return false, tostring(openError) end
  local wrote, writeError = file:write(content)
  file:close()
  if not wrote then
    pcall(filesystem.remove, tempPath)
    return false, tostring(writeError)
  end

  local valid, loaded = pcall(dofile, tempPath)
  if not valid or type(loaded) ~= "table" then
    pcall(filesystem.remove, tempPath)
    return false, "generated file failed validation: " .. tostring(loaded)
  end

  if filesystem.exists(backupPath) then
    local removed, removeError = filesystem.remove(backupPath)
    if not removed then
      pcall(filesystem.remove, tempPath)
      return false, "cannot replace backup: " .. tostring(removeError)
    end
  end

  local hadOriginal = filesystem.exists(path)
  if hadOriginal then
    local backedUp, backupError = filesystem.rename(path, backupPath)
    if not backedUp then
      pcall(filesystem.remove, tempPath)
      return false, "cannot create backup: " .. tostring(backupError)
    end
  end

  local replaced, replaceError = filesystem.rename(tempPath, path)
  if not replaced then
    if hadOriginal then pcall(filesystem.rename, backupPath, path) end
    pcall(filesystem.remove, tempPath)
    return false, "cannot install new config: " .. tostring(replaceError)
  end

  return true
end

function editorModule.create(options)
  assert(options and options.gpu and options.term and options.keyboard and options.computer,
         "target editor requires gpu, term, keyboard, and computer")
  assert(options.config and options.validate and options.apply,
         "target editor requires config, validate, and apply callbacks")

  local gpu = options.gpu
  local term = options.term
  local keyboard = options.keyboard
  local computer = options.computer
  local config = options.config
  local path = options.path or "/home/target_config.lua"

  local editor = {
    active = false,
    selected = 1,
    scroll = 0,
    draft = nil,
    dirty = false,
    hint = "",
    edit = nil,
    confirmClose = false,
    disabledValues = {},
    controlDown = false,
  }

  local itemNames = sortedKeys(config.dustTargets)

  local function totalRows()
    return GLOBAL_ROWS + #itemNames
  end

  local function selectedItemName()
    return itemNames[editor.selected - GLOBAL_ROWS]
  end

  local function isEnabled(itemName)
    local value = editor.draft.items[itemName]
    if value == false then return false end
    if type(value) == "table" and value.enabled == false then return false end
    if value ~= nil then return true end
    return editor.draft.keepAllMinedItems == true
  end

  local function itemTargetText(itemName)
    local value = editor.draft.items[itemName]
    if value == false then
      return "off"
    elseif type(value) == "table" and value.enabled == false then
      return value.target ~= nil and ("off (" .. tostring(value.target) .. ")") or "off"
    elseif value == nil or value == true then
      return "auto"
    elseif type(value) == "table" then
      if value.target ~= nil then return tostring(value.target) end
      if value.cellType then
        return tostring(value.cellType) .. " x" .. tostring(value.cellCount or 1)
      end
      return "auto"
    end
    return tostring(value)
  end

  local function itemInputText(itemName)
    local value = editor.draft.items[itemName]
    if value == false or (type(value) == "table" and value.enabled == false) then
      return "off"
    elseif type(value) == "table" then
      return value.target ~= nil and tostring(value.target) or "auto"
    elseif value == nil or value == true then
      return "auto"
    end
    return tostring(value)
  end

  local function setHint(message)
    editor.hint = tostring(message or "")
  end

  local function startEdit(label, value, commit)
    local text = tostring(value or "")
    editor.edit = {
      label = label,
      buffer = text,
      cursor = #text,
      commit = commit,
      replaceOnType = true,
    }
    editor.confirmClose = false
    setHint("Type to replace; arrows edit in place; Enter applies; Esc cancels.")
  end

  local function commitGlobal(index, text)
    text = trim(text)
    if index == 1 then
      if not editor.draft.CELL_CAPACITIES[text] then
        return false, "Unknown cell type: " .. text
      end
      editor.draft.currentCellType = text
    elseif index == 2 then
      local value = tonumber(text)
      if not value or value < 1 or value ~= math.floor(value) then
        return false, "Cell count must be a positive integer."
      end
      editor.draft.cellCount = value
    elseif index == 3 then
      local value = tonumber((text:gsub(",", ".")))
      if not value or value < 0 or value >= 1 then
        return false, "Safety margin must be at least 0 and below 1."
      end
      editor.draft.safetyMargin = value
    elseif index == 4 then
      local value = parseQty(text)
      if not value or value < 0 then
        return false, "Override must be 0 or a positive quantity such as 50m."
      end
      editor.draft.maxTargetOverride = value == 0 and 0 or text
    end
    editor.dirty = true
    return true
  end

  local function commitItem(itemName, text)
    text = trim(text)
    local normalized = string.lower(text)
    local oldValue = editor.draft.items[itemName]

    if normalized == "off" or normalized == "false" then
      if type(oldValue) == "table" then
        oldValue.enabled = false
        editor.draft.items[itemName] = oldValue
      elseif type(oldValue) == "string" or type(oldValue) == "number" then
        editor.draft.items[itemName] = { enabled=false, target=oldValue }
      else
        editor.draft.items[itemName] = false
      end
    elseif normalized == "" or normalized == "auto" or normalized == "true" then
      if type(oldValue) == "table" then
        oldValue.enabled = nil
        oldValue.target = nil
        editor.draft.items[itemName] = oldValue
      elseif editor.draft.keepAllMinedItems then
        editor.draft.items[itemName] = nil
      else
        editor.draft.items[itemName] = true
      end
    else
      local amount = parseQty(text)
      if not amount or amount <= 0 then
        return false, "Use auto, off, or a positive quantity such as 50m."
      end
      if type(oldValue) == "table" then
        oldValue.enabled = nil
        oldValue.target = text
        editor.draft.items[itemName] = oldValue
      else
        editor.draft.items[itemName] = text
      end
    end

    editor.dirty = true
    return true
  end

  local function beginSelectedEdit()
    if editor.selected <= GLOBAL_ROWS then
      if editor.selected == 5 then
        editor.draft.keepAllMinedItems = not editor.draft.keepAllMinedItems
        editor.dirty = true
        setHint("Keep-all mode " ..
                (editor.draft.keepAllMinedItems and "enabled." or "disabled."))
        return
      end
      local values = {
        editor.draft.currentCellType,
        editor.draft.cellCount,
        editor.draft.safetyMargin,
        editor.draft.maxTargetOverride or 0,
      }
      local labels = { "Cell type", "Cell count", "Safety margin", "Global override" }
      local index = editor.selected
      startEdit(labels[index], values[index], function(text)
        return commitGlobal(index, text)
      end)
    else
      local itemName = selectedItemName()
      startEdit(itemName, itemInputText(itemName), function(text)
        return commitItem(itemName, text)
      end)
    end
  end

  local function toggleSelectedItem()
    if editor.selected <= GLOBAL_ROWS then
      if editor.selected == 5 then beginSelectedEdit() end
      return
    end

    local itemName = selectedItemName()
    local current = editor.draft.items[itemName]
    if isEnabled(itemName) then
      editor.disabledValues[itemName] = {
        present = current ~= nil,
        value = clone(current),
      }
      if type(current) == "table" then
        current.enabled = false
        editor.draft.items[itemName] = current
      elseif type(current) == "string" or type(current) == "number" then
        editor.draft.items[itemName] = { enabled=false, target=current }
      else
        editor.draft.items[itemName] = false
      end
      setHint(itemName .. " disabled.")
    else
      local previous = editor.disabledValues[itemName]
      if type(current) == "table" and current.enabled == false then
        current.enabled = nil
        editor.draft.items[itemName] = current
      elseif previous then
        editor.draft.items[itemName] = previous.present and clone(previous.value) or nil
      elseif editor.draft.keepAllMinedItems then
        editor.draft.items[itemName] = nil
      else
        editor.draft.items[itemName] = true
      end
      setHint(itemName .. " enabled.")
    end
    editor.dirty = true
  end

  local function save()
    local valid, validationResult = pcall(options.validate, editor.draft)
    if not valid then
      setHint("NOT SAVED: " .. tostring(validationResult))
      return false
    end

    local written, writeError = writeAtomic(path, serializeTargetConfig(editor.draft))
    if not written then
      setHint("NOT SAVED: " .. tostring(writeError))
      return false
    end

    local applied, applyError = pcall(options.apply, clone(editor.draft))
    if not applied then
      setHint("Saved, but runtime apply failed: " .. tostring(applyError))
      return false
    end

    editor.dirty = false
    editor.confirmClose = false
    setHint("Saved and applied. Waiting for fresh dust telemetry.")
    return true
  end

  local function reload()
    local loaded, settings = pcall(dofile, path)
    if not loaded or type(settings) ~= "table" then
      setHint("Reload failed: " .. tostring(settings))
      return false
    end

    local valid, validationError = pcall(options.validate, settings)
    if not valid then
      setHint("Reload rejected: " .. tostring(validationError))
      return false
    end

    local applied, applyError = pcall(options.apply, clone(settings))
    if not applied then
      setHint("Reload could not be applied: " .. tostring(applyError))
      return false
    end

    editor.draft = clone(settings)
    editor.dirty = false
    editor.edit = nil
    editor.confirmClose = false
    editor.disabledValues = {}
    setHint("Reloaded from disk and applied.")
    return true
  end

  function editor:isOpen()
    return self.active
  end

  function editor:open()
    self.draft = clone(config.targetSettings)
    self.active = true
    self.dirty = false
    self.edit = nil
    self.confirmClose = false
    self.disabledValues = {}
    self.controlDown = keyboard.isControlDown()
    self.selected = math.max(1, math.min(self.selected, totalRows()))
    setHint("Edit targets while mining continues in the background.")
  end

  local function requestClose()
    if editor.edit then
      editor.edit = nil
      setHint("Edit cancelled.")
      return false
    end
    if editor.dirty and not editor.confirmClose then
      editor.confirmClose = true
      setHint("Unsaved changes. Press Esc again to discard, or Ctrl+S to save.")
      return false
    end
    editor.active = false
    editor.confirmClose = false
    return true
  end

  local function handleEditKey(char, code)
    local edit = editor.edit
    if code == ESC_KEY then
      editor.edit = nil
      setHint("Edit cancelled.")
    elseif code == keyboard.keys.enter or code == keyboard.keys.numpadenter then
      local ok, message = edit.commit(edit.buffer)
      if ok then
        editor.edit = nil
        setHint("Field updated. Press Ctrl+S to save and apply.")
      else
        setHint(message)
      end
    elseif code == keyboard.keys.left then
      edit.replaceOnType = false
      edit.cursor = math.max(0, edit.cursor - 1)
    elseif code == keyboard.keys.right then
      edit.replaceOnType = false
      edit.cursor = math.min(#edit.buffer, edit.cursor + 1)
    elseif code == keyboard.keys.home then
      edit.replaceOnType = false
      edit.cursor = 0
    elseif code == keyboard.keys["end"] then
      edit.replaceOnType = false
      edit.cursor = #edit.buffer
    elseif code == keyboard.keys.back then
      if edit.replaceOnType then
        edit.buffer = ""
        edit.cursor = 0
        edit.replaceOnType = false
      elseif edit.cursor > 0 then
        edit.buffer = edit.buffer:sub(1, edit.cursor - 1) ..
                      edit.buffer:sub(edit.cursor + 1)
        edit.cursor = edit.cursor - 1
      end
    elseif code == keyboard.keys.delete then
      if edit.replaceOnType then
        edit.buffer = ""
        edit.cursor = 0
        edit.replaceOnType = false
      elseif edit.cursor < #edit.buffer then
        edit.buffer = edit.buffer:sub(1, edit.cursor) ..
                      edit.buffer:sub(edit.cursor + 2)
      end
    elseif char and char >= 32 and char <= 126 then
      if edit.replaceOnType then
        edit.buffer = ""
        edit.cursor = 0
        edit.replaceOnType = false
      end
      local inserted = string.char(char)
      edit.buffer = edit.buffer:sub(1, edit.cursor) .. inserted ..
                    edit.buffer:sub(edit.cursor + 1)
      edit.cursor = edit.cursor + 1
    end
  end

  function editor:handleKey(char, code)
    if not self.active then return nil end
    if code == keyboard.keys.lcontrol or code == keyboard.keys.rcontrol then
      self.controlDown = true
      return nil
    end

    local controlDown = self.controlDown or keyboard.isControlDown()
    if self.edit and controlDown and code == keyboard.keys.s then
      local activeEdit = self.edit
      local committed, message = activeEdit.commit(activeEdit.buffer)
      if committed then
        self.edit = nil
        save()
      else
        setHint(message)
      end
    elseif self.edit then
      handleEditKey(char, code)
    elseif controlDown then
      if code == keyboard.keys.s then save()
      elseif code == keyboard.keys.r then reload()
      elseif code == keyboard.keys.w then
        if requestClose() then return "closed" end
      end
    elseif code == ESC_KEY then
      if requestClose() then return "closed" end
    elseif code == keyboard.keys.up then
      self.selected = (self.selected - 2) % totalRows() + 1
      self.confirmClose = false
    elseif code == keyboard.keys.down then
      self.selected = self.selected % totalRows() + 1
      self.confirmClose = false
    elseif code == keyboard.keys.pageUp then
      self.selected = math.max(1, self.selected - 10)
    elseif code == keyboard.keys.pageDown then
      self.selected = math.min(totalRows(), self.selected + 10)
    elseif code == keyboard.keys.home then
      self.selected = 1
    elseif code == keyboard.keys["end"] then
      self.selected = totalRows()
    elseif code == keyboard.keys.space then
      toggleSelectedItem()
    elseif code == keyboard.keys.enter or code == keyboard.keys.numpadenter then
      beginSelectedEdit()
    end

    return nil
  end

  function editor:handleKeyUp(code)
    if code == keyboard.keys.lcontrol or code == keyboard.keys.rcontrol then
      self.controlDown = false
    end
  end

  function editor:handleTouch(_, y)
    if not self.active then return nil end
    if y >= 5 and y <= 9 then
      self.selected = y - 4
    elseif y >= 12 then
      local index = self.scroll + (y - 11)
      if index >= 1 and index <= #itemNames then
        self.selected = GLOBAL_ROWS + index
      end
    end
    self.confirmClose = false
    return nil
  end

  local function drawRow(y, text, selected, color)
    local oldForeground = gpu.getForeground()
    local oldBackground = gpu.getBackground()
    if selected then
      gpu.setForeground(0x000000)
      gpu.setBackground(0xDDDDDD)
    else
      gpu.setForeground(color or 0xCCCCCC)
      gpu.setBackground(0x000000)
    end
    gpu.fill(1, y, select(1, gpu.getResolution()), 1, " ")
    gpu.set(2, y, text:sub(1, select(1, gpu.getResolution()) - 2))
    gpu.setForeground(oldForeground)
    gpu.setBackground(oldBackground)
  end

  local function drawInput(width, height)
    if not editor.edit then return end
    local edit = editor.edit
    local prefix = "EDIT " .. edit.label .. ": "
    local available = math.max(1, width - #prefix - 2)
    local viewStart = math.max(1, edit.cursor - available + 2)
    local visible = edit.buffer:sub(viewStart, viewStart + available - 1)
    local x = 2 + #prefix
    local y = height - 2

    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, y, width, 1, " ")
    gpu.set(2, y, prefix:sub(1, width - 2))
    if x <= width then gpu.set(x, y, visible) end

    -- Explicit block cursor: blink every 0.5 seconds at the insertion point.
    if math.floor(computer.uptime() * 2) % 2 == 0 then
      local cursorOffset = edit.cursor - (viewStart - 1)
      local cursorX = x + cursorOffset
      if cursorX >= x and cursorX <= width then
        local cursorChar = edit.buffer:sub(edit.cursor + 1, edit.cursor + 1)
        if cursorChar == "" then cursorChar = " " end
        gpu.setForeground(0x000000)
        gpu.setBackground(0xFFFFFF)
        gpu.set(cursorX, y, cursorChar)
        gpu.setBackground(0x000000)
      end
    end
  end

  function editor:draw()
    if not self.active then return end
    local width, height = gpu.getResolution()
    local visibleItems = math.max(1, height - 14)
    local selectedItem = math.max(1, self.selected - GLOBAL_ROWS)

    if self.selected > GLOBAL_ROWS then
      if selectedItem <= self.scroll then
        self.scroll = selectedItem - 1
      elseif selectedItem > self.scroll + visibleItems then
        self.scroll = selectedItem - visibleItems
      end
    end
    self.scroll = math.max(0, math.min(self.scroll, math.max(0, #itemNames - visibleItems)))

    gpu.setBackground(0x000000)
    gpu.setForeground(0x00FF00)
    term.clear()
    gpu.set(2, 1, "MEDINA TARGET EDITOR - mining and telemetry remain active")
    gpu.setForeground(0x666666)
    gpu.set(2, 2, ("FILE: " .. path):sub(1, width - 2))
    gpu.set(1, 3, string.rep("=", width))
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 4, "GLOBAL STORAGE SETTINGS")

    local globalValues = {
      { "Default cell type", tostring(self.draft.currentCellType) },
      { "Cell count", tostring(self.draft.cellCount) },
      { "Safety margin", tostring(self.draft.safetyMargin) },
      { "Global override", tostring(self.draft.maxTargetOverride or 0) },
      { "Keep all mined items", self.draft.keepAllMinedItems and "YES" or "NO" },
    }
    for index, entry in ipairs(globalValues) do
      drawRow(4 + index, string.format("%-25s : %s", entry[1], entry[2]),
              self.selected == index, index == 5 and 0x00FFFF or 0xCCCCCC)
    end

    gpu.setForeground(0x555555)
    gpu.set(1, 10, string.rep("-", width))
    gpu.setForeground(0xFFFFFF)
    gpu.set(2, 11, string.format(
      "ITEM TARGETS (%d known)   Space=toggle  Enter=edit target",
      #itemNames))

    local nameWidth = math.max(18, math.min(48, width - 35))
    for rowIndex = 1, visibleItems do
      local itemIndex = self.scroll + rowIndex
      local itemName = itemNames[itemIndex]
      if itemName then
        local enabled = isEnabled(itemName)
        local settings = self.draft.items[itemName]
        local priority = type(settings) == "table" and settings.priority or nil
        priority = priority or (config.dustTargets[itemName].priority or 99)
        local line = string.format("[%s] %-" .. nameWidth .. "s  %-14s P:%s",
          enabled and "x" or " ", itemName:sub(1, nameWidth),
          itemTargetText(itemName):sub(1, 14), tostring(priority))
        drawRow(11 + rowIndex, line,
                self.selected == GLOBAL_ROWS + itemIndex,
                enabled and 0xCCCCCC or 0x555555)
      end
    end

    drawInput(width, height)

    gpu.setBackground(0x000000)
    gpu.setForeground(editor.dirty and 0xFFAA00 or 0x777777)
    gpu.fill(1, height - 1, width, 1, " ")
    gpu.set(2, height - 1,
            ((editor.dirty and "* UNSAVED *  " or "") .. editor.hint):sub(1, width - 2))
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, height, width, 1, " ")
    gpu.set(2, height,
            "[Ctrl+S] Save+apply  [Ctrl+R] Reload  [Esc/Ctrl+W] Dashboard")
  end

  return editor
end

return editorModule
