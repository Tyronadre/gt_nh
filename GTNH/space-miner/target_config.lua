-- target_config.lua
-- User configuration for the Space Miner stock targets.
--
-- This file is intentionally separate from config.lua so project updates can
-- replace the asteroid/recipe database without overwriting your shopping list.

local targets = {}

--------------------------------------------------------------------------------
-- DEFAULT STORAGE TARGET
--
-- The default target is calculated like the target in space-pumping:
--
--   cell capacity * cell count * (1 - safety margin)
--
-- The capacities below are the maximum item count for ONE item type on an
-- otherwise empty AE2 item storage cell. If several item types share one
-- physical cell, lower the targets or give each entry an explicit target.
-- They account for AE2's per-type byte reservation rather than treating the
-- printed cell size as a raw item count.
--------------------------------------------------------------------------------
targets.currentCellType = "16384k"
targets.cellCount = 1
targets.safetyMargin = 0.20

-- Set to 0 to calculate from the cell settings above. A number or quantity
-- string such as "50m" replaces that calculation for every item which does not
-- have its own explicit target. This is useful for testing.
targets.maxTargetOverride = 0

targets.CELL_CAPACITIES = {
  ["1k"]     = 8128,
  ["4k"]     = 32512,
  ["16k"]    = 130048,
  ["64k"]    = 520192,
  ["256k"]   = 2080768,
  ["1024k"]  = 8323072,
  ["4096k"]  = 33292288,
  ["16384k"] = 133169152,
}

--------------------------------------------------------------------------------
-- ITEMS TO KEEP IN STOCK
--
-- Supported forms:
--   ["Diamond"] = true,                 -- use the default cell target
--   ["Diamond"] = "50m",                -- absolute target, short form
--   ["Diamond"] = { target = "50m" },   -- absolute target, extended form
--   ["Diamond"] = {
--     cellType = "4096k", cellCount = 2, safetyMargin = 0.10
--   },                                  -- per-item cell target
--   ["Diamond"] = { priority = 1 },      -- default cell target + priority
--   ["Diamond"] = false,                -- disabled; useful for quick toggles
--
-- Item names must exactly match config.dustTargets. Lower priority numbers are
-- mined first when the broker starts in Rarity mode.
--------------------------------------------------------------------------------
targets.items = {
  ["Cosmic Neutronium Dust"] = true,
  ["Diamond"]                 = true,
  ["Nether Star"]             = "1m",
  ["Infinity Catalyst Dust"]  = true,
  ["Plutonium 239 Dust"]      = "10m",
}

return targets
