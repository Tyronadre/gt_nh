-- installer.lua
-- Self-updating installer for GTNH Machine Monitor
-- Features: GitHub releases picker (touch/keyboard), progress UI, tar/zip extract, boot autostart, cleanup.

local term       = require("term")
local fs         = require("filesystem")
local shell      = require("shell")
local component  = require("component")
local gpu        = component.gpu
local event      = require("event")

-- Internet module: OC can provide either require("internet") or component.internet
local internet = nil
do
  local ok, mod = pcall(require, "internet")
  if ok and mod then internet = mod
  elseif component and component.isAvailable and component.isAvailable("internet") then
    internet = component.internet
  else
    error("No internet component/module available. Install a network card and try again.")
  end
end

-- === CONFIG ===
local REPO              = "Tyronadre/gt_nh"         -- owner/repo
local INSTALL_DIR       = "/home/gtnh_monitor"
local BOOT_FILE         = "/home/.shrc"             -- autostart via shell rc
local TMP_DIR           = "/tmp/gtnh_installer"
local TAR_PATH          = TMP_DIR .. "/release.tar.gz"
local ZIP_PATH          = TMP_DIR .. "/release.zip"
local USE_RC_ALWAYS     = true                      -- write boot to .shrc

-- === TINY JSON PARSER (rxi/json.lua style – minimized) ===
local json = {}
function json.parse(str)
  local pos = 1
  local function ws() local _,e = str:find("^[ \n\r\t]*",pos); pos=(e or pos-1)+1 end
  local function val()    
    ws() local c = str:sub(pos,pos)    
    if c == '"' then local i, res = pos+1, "" while i <= #str do local ch = str:sub(i,i) if ch == '"' then pos = i+1; return res        elseif ch == "\\" then          local n = str:sub(i+1,i+1); res = res .. (n == '"' or n == "\\" and n or ch); i = i + (n and 2 or 1)else res = res .. ch; i = i + 1 endend
    elseif c:match("[%d%-]") then
      local s,e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*",pos)
      local n = tonumber(str:sub(s,e)); pos = e+1; return n
    elseif str:sub(pos,pos+3) == "null"  then pos=pos+4; return nil
    elseif str:sub(pos,pos+3) == "true"  then pos=pos+4; return true
    elseif str:sub(pos,pos+4) == "false" then pos=pos+5; return false
    elseif c == "{" then      pos = pos+1; ws(); local t = {}      if str:sub(pos,pos) == "}" then pos = pos+1; return t end      while true do        ws(); local k = val(); ws(); pos = pos+1        local v = val(); t[k] = v; ws()        local ch = str:sub(pos,pos)        if ch == "}" then pos = pos+1; break end os = pos+1      end      return t
    elseif c == "[" then      pos = pos+1; ws(); local a = {}      if str:sub(pos,pos) == "]" then pos = pos+1; return a end      while true do        local v = val(); a[#a+1] = v; ws()        local ch = str:sub(pos,pos)        if ch == "]" then pos = pos+1; break end        pos = pos+1       end      return a
    else      error("JSON parse error at pos "..pos.." (char '"..(c or "?").."')")    end
  end
  return val()
end

-- === UTIL ===
local function ensureTmp()
  if fs.exists(TMP_DIR) then
    for file in fs.list(TMP_DIR) do fs.remove(fs.concat(TMP_DIR, file)) end
  else
    fs.makeDirectory(TMP_DIR)
  end
end

local function cleanupTmp()
  if fs.exists(TMP_DIR) then
    for file in fs.list(TMP_DIR) do fs.remove(fs.concat(TMP_DIR, file)) end
    fs.remove(TMP_DIR)
  end
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

local function fileWrite(path, data, mode)
  local f, e = io.open(path, mode or "wb")
  if not f then error("Open file failed: "..path.." ("..tostring(e)..")") end
  f:write(data); f:close()
end

local function hasFile(path) return fs.exists(path) end
local function hasCmdFile(cmd) return fs.exists("/bin/"..cmd) or fs.exists("/usr/bin/"..cmd) end

local function setColor(fg, bg)
  if gpu.setForeground then gpu.setForeground(fg) end
  if bg and gpu.setBackground then gpu.setBackground(bg) end
end

local function centerText(y, text)
  local w = ({gpu.getResolution()})[1]
  local x = math.max(1, math.floor((w - #text)/2) + 1)
  gpu.set(x, y, text)
end

local function drawBar(y, pct)
  local w = ({gpu.getResolution()})[1]
  local barW = math.max(10, math.floor(w * 0.6))
  local x = math.floor((w - barW)/2) + 1
  local fill = math.floor(barW * math.max(0, math.min(1, pct)))
  setColor(0x00FF00); gpu.fill(x, y, fill, 1, " ")
  setColor(0x444444); gpu.fill(x + fill, y, barW - fill, 1, " ")
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
  statusLine(h-2, msg, 0xAAAAFF)
  drawBar(h-1, step/total)
end

local function waitKeyOrTouch()
  while true do
    local ev = { event.pull() }
    if ev[1] == "key_down" or ev[1] == "touch" then return ev end
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
end

-- === EXTRACTORS ===
local function extractTarGz(tarPath, destDir)
  if not hasCmdFile("tar") then return false, "tar not found" end
  local cmd = string.format("tar -xzf %q -C %q", tarPath, destDir)
  local ok = os.execute(cmd)
  if not ok then return false, "tar extraction failed" end
  return true
end

local function extractZip(zipPath, destDir)
  if not hasCmdFile("unzip") then return false, "unzip not found" end
  local cmd = string.format("unzip -o %q -d %q", zipPath, destDir)
  local ok = os.execute(cmd)
  if not ok then return false, "unzip extraction failed" end
  return true
end

-- === BOOT AUTOSTART ===
local function writeBoot()
  local launcherPath = INSTALL_DIR .. "/launcher.lua"
  local bootContent = ([[-- Auto-start GTNH Machine Monitor
local fs = require("filesystem")
local shell = require("shell")
if fs.exists(%q) then
  shell.execute(%q)
end]]):format(launcherPath, launcherPath)
  local f, e = io.open(BOOT_FILE, "w")
  if not f then error("Failed to write boot file: "..tostring(e)) end
  f:write(bootContent); f:close()
end

-- === MAIN FLOW ===
local totalSteps = 7
local step = 0

local function nextStep(msg) step = step + 1; progress(step, totalSteps, msg) end

local function main()
  term.clear()
  -- Ensure reasonable resolution
  local setW, setH = 80, 25
  local curW, curH = gpu.getResolution()
  if curW < setW or curH < setH then pcall(function() gpu.setResolution(setW, setH) end) end

  -- 0. If already installed, ask reinstall
  setColor(0xFFFFFF)
  if fs.exists(INSTALL_DIR) then
    statusLine(4, "Already installed at "..INSTALL_DIR..". Reinstall? [Y/N]", 0xFFFF00)
    local ev = waitKeyOrTouch()
    if ev[1] == "key_down" then
      local _, _, _, code, _, ch = table.unpack(ev)
      if not (ch == 89 or ch == 121) then error("Installation aborted.") end
    elseif ev[1] == "touch" then
      -- Accept any touch as Yes for simplicity
    end
    -- wipe previous
    for f in fs.list(INSTALL_DIR) do fs.remove(fs.concat(INSTALL_DIR, f)) end
    fs.remove(INSTALL_DIR)
  end

  ensureTmp()

  -- 1. Fetch releases
  nextStep("Fetching releases from GitHub...")
  local releasesJSON = fetch("https://api.github.com/repos/"..REPO.."/releases", false)
  local releases = json.parse(releasesJSON)
  if not releases or #releases == 0 then error("No releases found for "..REPO) end

  -- 2. Pick release (touch UI)
  nextStep("Choose a version…")
  local release = pickRelease(releases)  -- throws on cancel
  local tag = release.tag_name or "<unknown>"

  -- 3. Decide extractor and asset URL (prefer tarball)
  nextStep("Preparing download…")
  local useTar = hasCmdFile("tar")
  local downloadUrl = nil
  local savePath = nil
  if useTar and release.tarball_url then
    nextStep("Using tar")
    downloadUrl = release.tarball_url
    savePath = TAR_PATH
  elseif release.zipball_url then
    nextStep("Using zip")
    downloadUrl = release.zipball_url
    savePath = ZIP_PATH
  else
    error("Release has neither tarball_url nor zipball_url.")
  end
  os.sleep(1000)

  -- 4. Download
  nextStep("Downloading "..tag.." …")
  local data = fetch(downloadUrl, true)  -- binary
  fileWrite(savePath, data, "wb")

  -- 5. Extract
  nextStep("Extracting files…")
  fs.makeDirectory(INSTALL_DIR)
  local ok, err
  if savePath == TAR_PATH then
    ok, err = extractTarGz(TAR_PATH, INSTALL_DIR)
    if not ok then
      -- try zip fallback
      if release.zipball_url and hasCmdFile("unzip") then
        local zipData = fetch(release.zipball_url, true)
        fileWrite(ZIP_PATH, zipData, "wb")
        ok, err = extractZip(ZIP_PATH, INSTALL_DIR)
      end
    end
  else
    ok, err = extractZip(ZIP_PATH, INSTALL_DIR)
  end
  if not ok then error("Extraction failed: "..tostring(err)) end

  -- NOTE: GitHub tarball/zip creates a top-level dir like: repo-<hash>/
  -- Move contents up if needed (first directory inside INSTALL_DIR)
  do
    local first = nil
    for name in fs.list(INSTALL_DIR) do first = name; break end
    if first and fs.isDirectory(fs.concat(INSTALL_DIR, first)) then
      local inner = fs.concat(INSTALL_DIR, first)
      for name in fs.list(inner) do
        fs.rename(fs.concat(inner, name), fs.concat(INSTALL_DIR, name))
      end
      fs.remove(inner)
    end
  end

  -- 6. Write boot autostart
  nextStep("Configuring autostart…")
  writeBoot()

  -- 7. Done
  nextStep("Cleaning up…")
  cleanupTmp()

  term.clear()
  setColor(0x00FF00); centerText(3, "Installation complete!"); setColor(0xFFFFFF)
  centerText(5, "Installed: "..INSTALL_DIR)
  centerText(7, "Auto-start configured via "..BOOT_FILE)
  centerText(9, "Press Enter to launch now, or any other key to exit.")
  local ev = { event.pull() }
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
