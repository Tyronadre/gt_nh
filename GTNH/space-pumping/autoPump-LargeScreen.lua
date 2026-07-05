local component = require("component")
local event = require("event")
local term = require("term")
local gpu = component.gpu
local config = require("config")

-- =================== HARDWARE INTERFACE ===================
local me = component.me_controller -- Proxy to ME Controller for querying fluid inventory
local pumps = {} -- Array of active pump objects (auto-populated by findPumps)
local running = true -- Main loop gate (set false to exit gracefully)
local currentMode = "Normal" -- Sorting algorithm for pump assignment (Normal/Stairstep/Waterfall)

-- Persistent Data Storage
local fluidDeltas = {} -- Percentage change per fluid since last snapshot (used for "TOP GROWTH" display)
local lastSnapshot = {} -- Previous fluid amounts (baseline for delta calculation)
local lastSnapshotTime = 0 -- Timestamp of last delta calculation
local snapshotInterval = 120 -- Ticks between delta recalculations (120 = ~6s for smoother, less noisy metrics)
local totalThroughput = 0 -- Net liters gained in last snapshot (raw production metric)

-- Scans OpenComputers component network for GT machines with specific pump tier names.
-- Assigns multipliers (4x/16x/256x) and thread counts based on tier.
-- Sorts by capacity (largest first) to assign high-demand fluids to powerful pumps.
local function findPumps()
  pumps = {}
  -- Maps pump module names to tier specifications.
  -- threads: Number of parallel extraction threads per pump (T1=1, T2=4, T3=4)
  -- mult: Flow rate multiplier applied to base Wiki rate (T1=4x, T2=16x, T3=256x)
  -- If using modded pumps, add entries here with custom multipliers.
  local tierLogic = {
    ["projectmodulepumpt1"] = {threads=1, mult=4,   label="T1"},
    ["projectmodulepumpt2"] = {threads=4, mult=16,  label="T2"},
    ["projectmodulepumpt3"] = {threads=4, mult=256, label="T3"}
  }
  for address in component.list('gt_machine') do
    local module = component.proxy(address)
    local name = module.getName()
    local p = {module=module, status="IDLE", task="None", addr=address:sub(1,4)}
    if tierLogic[name] then
      p.tier = tierLogic[name].label
      p.threads = tierLogic[name].threads
      p.mult = tierLogic[name].mult
      table.insert(pumps, p)
    end
  end
  table.sort(pumps, function(a, b)
    local capA = a.mult * a.threads
    local capB = b.mult * b.threads
    if capA ~= capB then return capA > capB end
    return a.addr < b.addr
  end)
end

-- =================== UTILITY & LOGIC ===================
local function formatFluid(amount)
  local suffixes = {' ', 'K', 'M', 'G', 'T', 'P'}
  local index = 1
  local value = amount
  while value >= 1000 and index < #suffixes do
    value = value / 1000
    index = index + 1
  end
  return string.format('%.2f %sL', value, suffixes[index])
end

-- Returns the storage limit for fluid filling (in liters).
-- If maxTargetOverride is set, use it (for testing at custom scales).
-- Otherwise, calculate from selected cell capacity minus safety margin.
local function getTarget()
  if config.maxTargetOverride and config.maxTargetOverride > 0 then
    return config.maxTargetOverride
  end
  local cap = config.CELL_CAPACITIES[config.currentCellType] or 0
  return cap * (1 - config.safetyMargin)
end

-- Syncs ME network state with config.master table.
-- Calculates deltas every snapshotInterval ticks (tracks production rate).
-- Sorts fluid list by demand mode (which fluids pumps should prioritize).
-- Returns list sorted by current mode: Normal prioritizes shortages, Stairstep uses tiers, Waterfall focuses on single item.
local function updateFluids(target)
  local list = {}
  local currentTime = os.time()
  
  for name, data in pairs(config.master) do data.amount = 0 end
  local networkFluids = me.getFluidsInNetwork()
  for _, fluid in ipairs(networkFluids) do
    if config.master[fluid.label] then
      config.master[fluid.label].amount = fluid.amount
    end
  end

  -- Snapshot Logic: Deltas & Throughput
  if (currentTime - lastSnapshotTime) >= snapshotInterval or lastSnapshotTime == 0 then
    local newDeltas = {}
    local cycleGain = 0
    for name, data in pairs(config.master) do
      local current = data.amount
      local old = lastSnapshot[name] or current
      newDeltas[name] = old > 0 and ((current - old) / old) * 100 or 0
      if current > old then cycleGain = cycleGain + (current - old) end
      lastSnapshot[name] = current 
    end
    fluidDeltas = newDeltas
    totalThroughput = cycleGain
    lastSnapshotTime = currentTime
  end

  for name, data in pairs(config.master) do
    table.insert(list, {
      label = name, amount = data.amount, priority = data.priority or 0,
      setting = data.setting, perc = (data.amount / target) * 100
    })
  end

  -- Needs-First Sorting by mode
  -- Normal: Pump anything below 100%, prioritize by configured priority, then by lowest amount. Good for balanced filling.
  -- Stairstep: Aggressive tiers (<10% critical, 10-50% moderate, 50%+ maintenance). Faster recovery from empty.
  -- Waterfall: All pumps focus on lowest-stocked item until full, then cascade to next. Sequential, orderly approach.
  if currentMode == "Normal" or currentMode == "Waterfall" then
    table.sort(list, function(a, b)
      local aNeeds = a.perc < 100 and 1 or 0
      local bNeeds = b.perc < 100 and 1 or 0
      if aNeeds ~= bNeeds then return aNeeds > bNeeds end
      if a.priority ~= b.priority then return a.priority > b.priority end
      return a.amount < b.amount
    end)
  elseif currentMode == "Stairstep" then
    table.sort(list, function(a, b)
      local stepA = a.perc < 10 and 1 or (a.perc < 50 and 2 or 3)
      local stepB = b.perc < 10 and 1 or (b.perc < 50 and 2 or 3)
      if stepA ~= stepB then return stepA < stepB end
      return a.priority > b.priority
    end)
  end
  return list
end

-- =================== UI RENDERING ===================
-- Renders real-time dashboard on large monitor (supports 4K+).
-- Sections: pump status (activity + current task), fluid demand (% full + absolute amount), and deltas (growth/reduction trends).
-- Colors indicate urgency: red (<50%), orange (50-95%), green (95-110%), magenta (>110%, overflow safe).
-- Throughput metric shows net liters gained in last 30 ticks across all fluids (production KPI).
local function drawUI(target, allFluids)
  term.clear()
  local w, h = gpu.getResolution()
  gpu.set(1, 1, string.rep("═", w))
  gpu.set(w/2-25, 1, " GTNH SPACE-GAS LOGISTICS TERMINAL - UEV TIER CONTROL ")
  gpu.set(2, 3, string.format("CELL: %s | SAFE: %d%% | MAX: %s", config.currentCellType, (1-config.safetyMargin)*100, formatFluid(target)))
  
  -- Pump Array
  gpu.set(1, 5, "║ PUMP ARRAY STATUS")
  gpu.set(1, 6, string.rep("─", w))
  for i, p in ipairs(pumps) do
    local col = i > 4 and (w/2 + 2) or 2
    local row = 7 + ((i-1)%4)
    gpu.set(col, row, string.format("[%d] | %s | ", i, p.tier))
    local active = p.module.isMachineActive()
    gpu.setForeground(active and 0x00FF00 or 0xAAAAAA)
    gpu.set(col + 13, row, string.format("%-8s", active and "WORKING" or "IDLE"))
    gpu.setForeground(0xFFFFFF)
    local fluidData = config.master[p.task]
    local tput = fluidData and (formatFluid(fluidData.rate * p.mult * p.threads) .. "/t") or "---"
    gpu.set(col + 24, row, string.format("| %-20s | %s", p.task, tput))
  end

  -- Demand Queue - displays all fluids in 3-column layout
  gpu.set(1, 12, "║ FLUID DEMAND QUEUE")
  gpu.set(1, 13, string.rep("─", w))
  for i, f in ipairs(allFluids) do
    if i > 40 then break end -- Display all 40 configured fluids
    local col = math.floor((i-1) / 14) -- 3 columns
    local row = 14 + ((i-1) % 14) -- 14 rows per column
    local x = col * math.floor(w/3) + 2
    local y = row
    if f.perc < 50 then gpu.setForeground(0xFF6666)
    elseif f.perc < 95 then gpu.setForeground(0xFFCC33)
    elseif f.perc < 110 then gpu.setForeground(0x00FF00)
    else gpu.setForeground(0xCC00FF) end
    gpu.set(x, y, string.format("%-14s | %8.4f%% | %s", f.label:sub(1,14), f.perc, formatFluid(f.amount)))
  end
  
  -- Split Diagnostic Deltas
  gpu.setForeground(0xFFFFFF)
  local tput = string.format(" (Throughput: %s)", formatFluid(totalThroughput))
  gpu.set(1, h-5, "║ NET DELTAS" .. tput)
  gpu.set(1, h-4, string.rep("─", w))
  
  local sortedDeltas = {}
  for name, d in pairs(fluidDeltas) do if d ~= 0 then table.insert(sortedDeltas, {n=name, v=d}) end end
  table.sort(sortedDeltas, function(a, b) return a.v > b.v end)

  gpu.setForeground(0x00FF00); gpu.set(2, h-3, "TOP GROWTH:")
  for i = 1, 3 do
    local d = sortedDeltas[i]
    if d and d.v > 0 then gpu.set(2, (h-3)+i, string.format("%-14s: %+9.4f%%", d.n:sub(1,14), d.v)) end
  end

  gpu.setForeground(0xFF6666); gpu.set(w/2 - 5, h-3, "TOP REDUCTIONS:")
  for i = 1, 3 do
    local d = sortedDeltas[#sortedDeltas - (i-1)]
    if d and d.v < 0 then gpu.set(w/2 - 5, (h-3)+i, string.format("%-14s: %+9.4f%%", d.n:sub(1,14), d.v)) end
  end

  -- Footer
  gpu.setForeground(0xFFFFFF)
  gpu.set(2, h, string.format("TARGET: %s", formatFluid(target)))
  local modes = {{"[N]ormal", "Normal"}, {"[S]tairstep", "Stairstep"}, {"[W]aterfall", "Waterfall"}}
  local startX = w - 55
  for _, m in ipairs(modes) do
    if currentMode == m[2] then gpu.setForeground(0x00FF00); gpu.set(startX, h, ">" .. m[1])
    else gpu.setForeground(0xFFFFFF); gpu.set(startX, h, " " .. m[1]) end
    startX = startX + 15
  end
end

-- =================== EXECUTION ===================
-- Ensures all pumps are idle before main loop starts (safety check).
-- Prevents race conditions where pumps finish/restart during initialization.
-- 5-second delay gives ME Controller time to sync inventory after module reset.
local function preLaunch()
  term.clear()
  findPumps()
  local w, _ = gpu.getResolution()
  gpu.set(1, 1, string.rep("═", w))
  gpu.set(3, 1, " SYSTEM PRE-LAUNCH CHECK ")
  gpu.set(1, 2, string.rep("═", w))
  gpu.set(2, 4, "INITIATING HARDWARE SEQUENCING...")
  for _, p in ipairs(pumps) do p.module.setWorkAllowed(false) end
  local allIdle = false
  while not allIdle do
    allIdle = true
    updateFluids(getTarget())
    for i, p in ipairs(pumps) do
      local active = p.module.isMachineActive()
      if active then allIdle = false end
      gpu.set(4, 9 + i, string.format("Module Array [%d]: ", i)); gpu.setForeground(active and 0xFF6666 or 0x00FF00)
      gpu.set(22, 9 + i, active and "BUSY   " or "CLEARED"); gpu.setForeground(0xFFFFFF)
    end
    if not allIdle then os.sleep(1) end
  end
  os.sleep(5)
end

preLaunch()
while running do
  local target = getTarget()
  local allFluids = updateFluids(target)
  local lowFluids = {}
  for _, f in ipairs(allFluids) do if f.amount < target then table.insert(lowFluids, f) end end
  -- Each tick, checks idle pumps and assigns next fluid from demand queue.
  -- Sets planet/slot parameters based on fluid.setting from config.
  -- Waterfall mode ignores pump index; other modes assign queue[index] to pump[index].
  -- Work gate (setWorkAllowed) momentarily enables pump to execute task, then disables (prevents runaway).
  for i, p in ipairs(pumps) do
    if not p.module.isMachineActive() then
      local fluid = (currentMode == "Waterfall") and lowFluids[1] or (lowFluids[i] or lowFluids[1])
      if fluid then
        for t=1, p.threads do p.module.setParameters(2*(t-1), 0, fluid.setting[1]); p.module.setParameters(2*(t-1), 1, fluid.setting[2]) end
        p.module.setParameters(9, 1, 30); p.module.setWorkAllowed(true); os.sleep(0.1); p.module.setWorkAllowed(false); p.task = fluid.label
      else p.task = "None" end
    end
  end
  drawUI(target, allFluids)
  local _, _, char = event.pull(1, "key_down")
  -- Keyboard controls:
  -- [N]: Switch to Normal mode (balanced prioritization)
  -- [S]: Switch to Stairstep mode (aggressive tiers)
  -- [W]: Switch to Waterfall mode (single-focus cascade)
  -- [Q]: Quit (gracefully stops main loop and exits script)
  if char == 110 then currentMode = "Normal"
  elseif char == 115 then currentMode = "Stairstep"
  elseif char == 119 then currentMode = "Waterfall"
  elseif char == 113 then running = false end
end