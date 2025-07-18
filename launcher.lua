local fs    = require("filesystem")
local term  = require("term")
local os    = require("os")
local component = require("component")
local gpu   = component.gpu

-- Config
local mapping_file      = "/home/f_machine_mapping.lua"
local editor_script     = "/home/mapping_editor.lua"
local display_script    = "/home/machine_display.lua"

-- Vars
local screenW, screenH = gpu.getResolution()

local function clearScreen()
  gpu.setResolution(screenW, screenH)
  term.clear()
  term.setCursor(1,1)
end

local function pause()
  io.write("\nPress Enter to continue...")
  io.read()
end

local function showMenu()
  clearScreen()
  print("== Machine Array Launcher ==")
  print()
  print("1) Edit mapping")
  if fs.exists(mapping_file) then
    print("2) Run machine array display")
  else
    print("2) Run machine array display (no mapping file created)")
  end
  print("0) Exit")
  io.write("\nSelect an option: ")
end

while true do
  showMenu()
  local choice = io.read():match("%d")
  if choice == "1" then
    -- Launch the editor
    clearScreen()
    print("Launching Mapping Editor...\n")
    os.execute(editor_script)
    pause()
  elseif choice == "2" then
    clearScreen()
    print("Launching Machine Array Display...\n")
    os.execute(display_script)
    pause()
  elseif choice == "0" then
    clearScreen()
    print("Goodbye!")
    break
  else
    print("\nInvalid selection.")
    pause()
  end
end
