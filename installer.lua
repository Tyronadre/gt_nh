-- installer.lua
-- Self-updating installer for GTNH Machine Monitor
-- Features: GitHub releases picker (touch/keyboard), progress UI, tar/zip extract, boot autostart, cleanup.

local term       = require("term")
local fs         = require("filesystem")
local shell      = require("shell")
local component  = require("component")
local gpu        = component.gpu
local event      = require("event")
local keyboard   = require("keyboard")

-- == CHECK FOR INTERNET CARD
local internet = nil
do
  local ok, mod = pcall(require, "internet")
  if ok and mod then internet = mod
  else
    error("No internet component/module available. Install a network card and try again.")
  end
end

-- == JSON AND TAR INSTALLER
local jsonLib = "https://raw.githubusercontent.com/rxi/json.lua/refs/heads/master/json.lua"

-- === CONFIG ===
local VERSION           = "1.1"
local REPO              = "Tyronadre/gt_nh"         -- owner/repo
local INSTALL_DIR       = "/home/gtnh_monitor"
local BOOT_FILE         = "/home/.shrc"             -- autostart via shell rc
local TMP_DIR           = "/tmp/gtnh_installer"
local ZIP_PATH          = TMP_DIR .. "/release.zip"
local USE_RC_ALWAYS     = true                      -- write boot to .shrc

-- == VARIABLES
local totalSteps = 6
local step = 0

-- === UTIL ===
local function ensureTmp()
  if fs.exists(TMP_DIR) then
    -- clean previous
    for file in fs.list(TMP_DIR) do fs.remove(fs.concat(TMP_DIR, file)) end
  else
    fs.makeDirectory(TMP_DIR)
  end
end

local function cleanupTmp()
  fs.remove(TMP_DIR)
end

local function writeFile(path, data, overwrite)
  if overwrite then
    if fs.exists(path) then fs.remove(path) end
  elseif fs.exists(path) then error("File at "..path.." exists already.") end
  
  local f, e = io.open(path, "w")
  if e then error("Error while opening file at "..path..": \n"..tostring(e)) end
  f:write(data)
  f:close()
end

local function fetch(url, binary)
  local handle, err = internet.request(url)
  if not handle then error("HTTP request failed: "..tostring(err)) end
  local out = binary and {} or ""
  for chunk in handle do
    if binary then out[#out+1] = chunk else out = out .. chunk end
  end
  return binary and table.concat(out) or out
end

local function setColor(fg, bg)
  if gpu.setForeground then gpu.setForeground(fg) end
  if bg and gpu.setBackground then gpu.setBackground(bg) end
end

local function centerText(startY, text)
  local w = ({gpu.getResolution()})[1]

  local lines = {}
  for line in text:gmatch("[^\n]+") do
    while #line > w do
      table.insert(lines, line:sub(1, w))
      line = line:sub(w + 1)
    end
    table.insert(lines, line)
  end

  local y = startY
  for _, line in ipairs(lines) do
    local x = math.max(1, math.floor((w - #line) / 2) + 1)
    gpu.set(x, y, line)
    y = y + 1
  end
end

local function drawBar(y, pct)
  local w = ({gpu.getResolution()})[1]
  local barW = math.max(10, math.floor(w * 0.6))
  local x = math.floor((w - barW)/2) + 1
  local fill = math.floor(barW * math.max(0, math.min(1, pct)))
  setColor(0x00FF00); gpu.fill(x, y, fill, 1, "█")
  setColor(0x444444); gpu.fill(x + fill, y, barW - fill, 1, "█")
  setColor(0xFFFFFF)
end

local function statusLine(line, msg, color)
  setColor(color or 0xFFFFFF)
  term.setCursor(1, line); term.clearLine()
  centerText(line, msg)
  setColor(0xFFFFFF)
end

local function progress(step, total, msg)
  local _, h = gpu.getResolution()
  statusLine(h-4, msg, 0xAAAAFF)
  drawBar(h-3, step/total)
end

local function nextStep(msg) step = step + 1; progress(step, totalSteps, msg) end

local function msg(msg) progress(step, totalSteps, msg) end

local function waitKeyOrTouch()
  while true do
    local ev = { event.pull() }
    if ev[1] == "key_down" or ev[1] == "touch" then return ev end
  end
end

-- Checks if this installer is of the newest release version. if it is this function return nil, otherwise the release with the newest version
local function checkVersion(releases) 
  local newestRelease = nil
  for _, release in ipairs(releases) do
    local releaseVersion = release.tag_name
    if VERSION < releaseVersion then
      if not newestRelease then newestRelease = release
      elseif newestRelease.tag_name < releaseVersion then newestRelease = release end
    end
  end
  if newestRelease == "0.0.0" then return nil else return newestRelease end
end

local function updateInstaller(release) 
  for _, asset in ipairs(release.assets) do
    local assetName = asset.name
    msg("Downloading "..assetName)
    if assetName == "installer.lua" then writeFile("/home/installer.lua", fetch(asset.browser_download_url), true) end
    msg("Executing new installer")
    os.sleep(1)
    os.execute("/home/installer.lua")
  end
end

-- === UI: releases picker (touch + keyboard) ===
local function pickRelease(releases)
  term.clear()
  local w, h = gpu.getResolution()
  setColor(0xFFFF00); centerText(1, "GTNH Machine Monitor — Installer"); setColor(0xFFFFFF)
  centerText(3, "Select a version to install (tap a line or use arrows + Enter)")
  local top = 5
  local maxShow = h - top - 4
  local start = 1
  local sel = 1

  local function draw()
    for i = 0, maxShow-1 do
      term.setCursor(1, top+i); term.clearLine()
      local idx = start + i
      if releases[idx] then
        local label = string.format("%2d) %s", idx, releases[idx].tag_name or ("release "..idx))
        if idx == sel then setColor(0x000000, 0xAAAAFF); gpu.fill(1, top+i, w, 1, " "); setColor(0x000000) end
        gpu.set(3, top+i, label:sub(1, w-4))
        setColor(0xFFFFFF, 0x000000)
      end
    end
    centerText(h, "[Up/Down] move   [Enter/Tap] select   [Q] quit")
  end

  draw()
  while true do
    local ev = { event.pull() }
    if ev[1] == "key_down" then
      local _, _, _, code, _, ch = table.unpack(ev)
      if code == 200 then -- up
        sel = math.max(1, sel-1); if sel < start then start = sel end; draw()
      elseif code == 208 then -- down
        sel = math.min(#releases, sel+1); if sel >= start + maxShow then start = sel - maxShow + 1 end; draw()
      elseif code == 28 then -- enter
        return releases[sel]
      elseif code == 16 or ch == 113 then -- Q/q
        error("Cancelled by user.")
      end
    elseif ev[1] == "touch" then
      local _, _, x, y = table.unpack(ev)
      if y >= top and y < top + maxShow then
        local idx = start + (y - top)
        if releases[idx] then return releases[idx] end
      end
    end
  end
  term.clear()
end

-- === BOOT AUTOSTART ===
local function writeBoot()
  local f, e = io.open(BOOT_FILE, "w")
  if not f then error("Failed to write boot file: "..tostring(e)) end
  f:write(INSTALL_DIR .. "/machine_display.lua"); f:close()
end

-- === MAIN ===
local function main()
  term.clear()
  -- Ensure reasonable resolution
  local setW, setH = 80, 25
  local curW, curH = gpu.getResolution()
  if curW < setW or curH < setH then pcall(function() gpu.setResolution(setW, setH) end) end

  -- 0. Install Libs
  nextStep("Installing Libraries")
  shell.setWorkingDirectory("/lib")
  if not fs.exists("/lib/json.lua") then 
    msg("Installing JSON")
    shell.execute("wget -fq " .. jsonLib)
  end
  shell.setWorkingDirectory("/home")
  msg("Libraries installed")
  os.sleep(1)

  -- 2. Fetch releases
  nextStep("Fetching releases from GitHub...")
  local releasesJSON = fetch("https://api.github.com/repos/"..REPO.."/releases", false)
  local json = require("json")
  local releases = json.decode(releasesJSON)
  if not releases or #releases == 0 then error("No releases found for "..REPO) end
  local versionCheck = checkVersion(releases)
  print(checkVersion)
  if versionCheck then 
    msg("Found a newer version (" .. versionCheck.tag_name .." of the installer. Updating!")
    os.sleep(1)
    updateInstaller(versionCheck) 
    exit()
  end

  -- 3. Pick release
  nextStep("Choose a version…")
  local release = pickRelease(releases)
  local tag = release.tag_name or error("This release has not tag name")
  
  -- 4. Download
  term.clear()
  nextStep("Preparing download…")
  fs.makeDirectory(INSTALL_DIR)
  local _, h = gpu.getResolution()
  local numberOfFiles = #(release.assets)
  if not release.assets or numberOfFiles == 0 then error("Release has no assets") end
  for index, asset in ipairs(release.assets) do 
    local filename = asset.name
    local destFile = INSTALL_DIR.."/"..asset.name
    if not filename:match("%.lua") then goto continue end
    if filename:match("installer.lua") then goto continue end
    statusLine(h-2, "Downloading "..filename.." ("..index.."/"..numberOfFiles..")", 0xAAAAFF)
    drawBar(h-1, index/numberOfFiles)
    writeFile(destFile,fetch(asset.browser_download_url, false), true)
    ::continue::
  end

  -- 5. Write boot autostart
  term.clear()
  nextStep("Configuring autostart…")
  writeBoot()
  os.sleep(1)

  -- 6. Done
  nextStep("Cleaning up…")
  cleanupTmp()
  os.sleep(1)

  term.clear()
  setColor(0x00FF00); centerText(3, "Installation complete!"); setColor(0xFFFFFF)
  centerText(5, "Installed: "..INSTALL_DIR)
  centerText(7, "Auto-start configured via "..BOOT_FILE)
  centerText(9, "Press Enter to launch now, or any other key to exit.")
  local ev = { event.pull() }
  term.clear()
  if ev[1] == "key_down" and select(4, table.unpack(ev)) == 28 then
    shell.execute(INSTALL_DIR.."/launcher.lua")
  end
end

-- Run with robust cleanup
local ok, err = pcall(main)
cleanupTmp()
if not ok then
  term.clear()
  setColor(0xFF5555); centerText(3, "Installation failed"); setColor(0xFFFFFF)
  centerText(5, tostring(err))
  centerText(7, "(Temp files cleaned up)")
end
