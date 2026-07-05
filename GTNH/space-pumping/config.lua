local config = {}

-- ===================== CORE CONFIGURATION ===================
-- currentCellType: ME fluid cell size in use (options: 1k, 4k, 16k, 64k, 256k, 1024k, 4096k, 16384k, Quantum)
-- safetyMargin: Fraction of cell capacity to reserve (e.g., 0.20 = stop at 80% full to prevent overflow)
-- maxTargetOverride: Set to 0 to auto-calculate from cell capacity; non-zero value forces a static target (useful for testing)
config.currentCellType = "16384k"
config.safetyMargin = 0.20
config.maxTargetOverride = 1000000000 -- set to 1G liters for testing 

-- ME Fluid Cell Capacities (in Liters). Calculated from AE2 ME fluid cell specs.
-- Use these to determine storage limits and pump target percentages.
config.CELL_CAPACITIES = {
    ["1k"]      = 2080000,      -- 2.08M Liters
    ["4k"]      = 8320000,      -- 8.32M Liters
    ["16k"]     = 33300000,     -- 33.3M Liters
    ["64k"]     = 133000000,    -- 133M Liters
    ["256k"]    = 533000000,    -- 533M Liters
    ["1024k"]   = 2130000000,   -- 2.13G Liters
    ["4096k"]   = 8520000000,   -- 8.52G Liters
    ["16384k"]  = 34100000000,  -- 34.1G Liters
    ["Quantum"] = 275000000000, -- 275G Liters
}

-- ===================== FLUID MASTER LIST ===================
-- Rates are extracted from GTNH Wiki (listed as L/s).
-- Divide Wiki value by 20 to convert to liters per tick (OC clock runs at 20 Hz).
-- Final throughput = rate * pump_multiplier * thread_count (multipliers: T1=4x, T2=16x, T3=256x applied in main script)
--
-- priority: Controls fill order (0-5, higher = pump sooner). Use 4-5 for critical/endgame materials.
-- amount: Automatically populated by main script; stores current fluid quantity in ME network.
-- setting: {planet_number, output_slot} coordinates on space station. Match your base layout.
-- rate: Liters per second (from Wiki) ÷ 20. Represents extraction rate per pump thread per tick.

config.master = {
  -- Planet 2
  ['Chlorobenzene']     = {priority=0, amount=0, setting={2,1},  rate=44800},
  -- Planet 3
  ['Ender Goo']         = {priority=0, amount=0, setting={3,1},  rate=1600},
  ['Very Heavy Oil']    = {priority=0, amount=0, setting={3,2},  rate=70000},
  ['Lava']              = {priority=0, amount=0, setting={3,3},  rate=90000},
  ['Natural Gas']       = {priority=0, amount=0, setting={3,4},  rate=70000},
  -- Planet 4
  ['Sulfuric Acid']     = {priority=5, amount=0, setting={4,1},  rate=39200},
  ['Molten Iron']       = {priority=0, amount=0, setting={4,2},  rate=44800},
  ['Oil']               = {priority=4, amount=0, setting={4,3},  rate=70000},
  ['Heavy Oil']         = {priority=0, amount=0, setting={4,4},  rate=89600},
  ['Molten Lead']       = {priority=0, amount=0, setting={4,5},  rate=44800},
  ['Raw Oil']           = {priority=0, amount=0, setting={4,6},  rate=70000},
  ['Light Oil']         = {priority=0, amount=0, setting={4,7},  rate=39000},
  ['Carbon Dioxide']    = {priority=0, amount=0, setting={4,8},  rate=84000},
  -- Planet 5
  ['Carbon Monoxide']   = {priority=0, amount=0, setting={5,1},  rate=224000},
  ['Helium-3']          = {priority=4, amount=0, setting={5,2},  rate=140000},
  ['Salt Water']        = {priority=0, amount=0, setting={5,3},  rate=140000},
  ['Helium']            = {priority=5, amount=0, setting={5,4},  rate=70000},
  ['Liquid Oxygen']     = {priority=0, amount=0, setting={5,5},  rate=44800},
  ['Neon']              = {priority=0, amount=0, setting={5,6},  rate=1600},
  ['Argon']             = {priority=0, amount=0, setting={5,7},  rate=1600},
  ['Krypton']           = {priority=0, amount=0, setting={5,8},  rate=400},
  ['Methane']           = {priority=2, amount=0, setting={5,9},  rate=89600},
  ['Hydrogen Sulfide']  = {priority=0, amount=0, setting={5,10}, rate=19600},
  ['Ethane']            = {priority=0, amount=0, setting={5,11}, rate=59700},
  -- Planet 6
  ['Deuterium']         = {priority=5, amount=0, setting={6,1},  rate=78400},
  ['Tritium']           = {priority=5, amount=0, setting={6,2},  rate=12000},
  ['Ammonia']           = {priority=4, amount=0, setting={6,3},  rate=12000},
  ['Xenon']             = {priority=5, amount=0, setting={6,4},  rate=800},
  ['Ethylene']          = {priority=2, amount=0, setting={6,5},  rate=89600},
  -- Planet 7
  ['Hydrofluoric Acid'] = {priority=4, amount=0, setting={7,1},  rate=33600},
  ['Fluorine']          = {priority=4, amount=0, setting={7,2},  rate=89600},
  ['Nitrogen']          = {priority=2, amount=0, setting={7,3},  rate=89600},
  ['Oxygen']            = {priority=2, amount=0, setting={7,4},  rate=86450},
  -- Planet 8
  ['Hydrogen']          = {priority=5, amount=0, setting={8,1},  rate=78400},
  ['Liquid Air']        = {priority=0, amount=0, setting={8,2},  rate=43750},
  ['Molten Copper']     = {priority=0, amount=0, setting={8,3},  rate=33600},
  ['Unknown Liquid']    = {priority=4, amount=0, setting={8,4},  rate=33600},
  ['Distilled Water']   = {priority=5, amount=0, setting={8,5},  rate=896000},
  ['Radon']             = {priority=5, amount=0, setting={8,6},  rate=3200},
  ['Molten Tin']        = {priority=0, amount=0, setting={8,7},  rate=33600}
}

return config