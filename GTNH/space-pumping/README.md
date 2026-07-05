# GTNH Space Gas Logistics Terminal

An OpenComputers automation script for GTNH (GregTech New Horizons) that manages planetary space gas extraction using Space Elevator Pumping Modules. Automatically prioritizes fluid collection across multiple planets and displays real-time production analytics.

## Overview

This OpenComputers script controls Space Pumping Modules in any tier (T1, T2, T3) to extract gases and fluids from planets automatically switching between the different spaces and fluids. The main script (`autoPump-LargeScreen.lua`) orchestrates pump operations based on configurable demand, while `config.lua` defines fluid sources, extraction rates, and storage targets.

**Features:**
- **Multi-planet fluid extraction** from 7 planets with 40 unique fluids
- **Intelligent prioritization** using 3 sorting modes (Normal, Stairstep, Waterfall)
- **Real-time analytics**: throughput tracking, delta monitoring, demand percentages
- **Pump tier detection**: Automatically identifies T1 (1x), T2 (16x), and T3 (256x) pumps
- **Configurable storage targets**: Based on ME fluid cell capacities with safety margins
- **Large display support**: Supports a matrix of 6 T3 Screens (2 high-3 wide)

## Hardware Requirements

### Minimum Setup
- **OpenComputers computer** (case, CPU, RAM, hard drive)
- **ME Controller** with interface to network
- **Internet Card** (to download via wget the script from here on GitHub)
- **1x Space Pumping Module T1** minimum
- **Graphics Card T3**
- **Adapters mapped to each Space Pumping Module and ME Controller for Fluid Subnet**  

### Optimal Setup
- **Computer with T3 CPU or T3 APU**
- **2x Tier 3.5 Memory Cards**
- **Multiple pump tiers** (T1 + T2 + T3 for max flexibility)
- **T3 Screen** 

## Installation

1. **Copy scripts to OpenComputers hard drive using wget:**
   ```
   /space-pumping/config.lua
   /space-pumping/autoPump-LargeScreen.lua
   ```

2. **Configure your setup** in `config.lua`:
   - Update `currentCellType` to match your ME fluid storage cells
   - Adjust `safetyMargin` (0.20 = 20% buffer before cell full)
   - If you aren't testing, make sure to set the config.maxTargetOverride value to 0
   - Rates already calculated based on Wiki (pre-configured values / 20 to convert to L/tick)

3. **Run the script:**
   ```
   autoPump-LargeScreen.lua
   ```

## Configuration Guide

### Core Settings (config.lua)

```lua
config.currentCellType = "16384k"    -- ME cell size you're using
config.safetyMargin = 0.20            -- Stop collecting at 80% full
config.maxTargetOverride = 1000000000 -- Override target (use 0 to disable)
```

**Cell Capacities:**
Pre-configured for AE2 fluid cells. If using different cells, update the `CELL_CAPACITIES` table with your cell sizes in liters.

### Fluid Master List

Each fluid entry requires:
- **priority**: 0-5 (higher = pump sooner when below target)
- **setting**: `{planet, output_slot}` - coordinates on space station
- **rate**: L/s from Wiki ÷ 20 (for liters per tick)

Example:
```lua
['Hydrogen'] = {priority=5, amount=0, setting={8,1}, rate=78400}
```

**Rates Explained:**
- Wiki states rates in L/s (liters per second)
- Divide by 20 to get liters per tick (OC clock)
- T1 pumps: ×4 multiplier
- T2 pumps: ×16 multiplier  
- T3 pumps: ×256 multiplier

## Operating Modes

Press **N**, **S**, or **W** while running to switch modes. **Q** to quit.

### Normal Mode
- Prioritize any fluid below target (100%)
- Within those, pump higher-priority items first
- Then by lowest stored amount
- **Best for:** Balanced filling, especially with priority-4/5 items

### Stairstep Mode
- Pump anything below 10% first
- Then 10-50%, then 50%+
- Respects priority within each tier
- **Best for:** Rapid recovery from empty tanks, dramatic catch-up

### Waterfall Mode
- All pumps focus on the single lowest-stocked item
- Pump it to full capacity
- Then move to next in queue
- **Best for:** Sequential completions, avoiding scatter

## Dashboard Explanation

```
GTNH SPACE-GAS LOGISTICS TERMINAL - UEV TIER CONTROL
CELL: 16384k | SAFE: 80% | MAX: 27.28 GL

║ PUMP ARRAY STATUS
[1] | T3 | WORKING | Hydrogen | 20.06 ML/t
[2] | T2 | IDLE    | None     | ---
[3] | T1 | WORKING | Deuterium| 1.57 ML/t

║ FLUID DEMAND QUEUE
Hydrogen      | 85.4321% | 23.13 GL
Deuterium     | 45.6789% | 12.36 GL
...

║ NET DELTAS (Throughput: 150.23 ML)
TOP GROWTH:
Hydrogen      : +15.2341%
Deuterium     : +8.9234%

TOP REDUCTIONS:
Heavy Oil     : -3.4521%

TARGET: 27.28 GL
[N]ormal  [S]tairstep  [W]aterfall
```

**Color Coding:**
- **Red** (<50%): Critical shortage
- **Orange** (50-95%): Ramping up
- **Green** (95-110%): Target achieved
- **Magenta** (>110%): Overflow (space exists)

**Throughput:** Net liters gained in the last 30 seconds across all fluids.

## Troubleshooting

### Pumps Won't Start
- Check ME Controller address in logs (should auto-detect)
- Ensure they're connected to the adapter
- Is the Space Elevator powered?
- Do you have enough computation for the module?
- Ensure planet/slot settings match actual space station layout
- Run `findPumps()` debug function to list detected modules

### Storage Filling Unexpectedly
- Lower `safetyMargin` (e.g., 0.10 for 10% buffer)
- Disable low-priority items (set rate=0)
- Use Waterfall mode to focus on fewer fluids at once

### High CPU Usage
- Reduce monitor resolution if possible
- Disable color formatting (edit `drawUI()`)
- Increase `snapshotInterval` (line 17, default 30 = 30 ticks)

### Changing config.lua values don't take effect
- Reboot the Space Pumping computer, sometimes values don't take effect until reboot.

## Architecture

- **Hardware Detection:** Auto-scans for GT machines, identifies pump tiers
- **Fluid Tracking:** Snapshots ME network every 30 ticks, calculates deltas
- **Demand Sorting:** Three algorithms (Normal/Stairstep/Waterfall) for assignment
- **Pump Control:** Sets planet/slot parameters, gates work with enable/disable
- **UI Rendering:** Multi-column layout with color-coded demand and live throughput

## Advanced Customization

### Add a New Fluid
1. Look up the fluid on the GTNH Wiki
2. Find extraction rate (L/s)
3. Add to `config.master`:
   ```lua
   ['NewFluid'] = {priority=2, amount=0, setting={planet,slot}, rate=rateValue},
   ```

### Change Pump Behavior
- Edit `tierLogic` table (line 22) to add new pump types
- Adjust multipliers if using modded tiers
- Modify sorting logic in `updateFluids()` for custom prioritization

### Customize Display
- Edit color values in `drawUI()` (hex format like `0xFF6666`)
- Change column layout calculations if using different monitor size
- Adjust fluid list length with `if i > 30 then break end` (line 149)

## Notes

- **First run:** System performs 5-second pre-launch check to ensure all pumps idle
- **Snapshot interval:** Every 30 ticks (1.5 seconds) for delta calculations
- **Thread model:** Each pump tier has fixed thread count (T1=1, T2=4, T3=4)
- **Safety margin:** Prevents overflow; recommend 0.15-0.25 (15-25% buffer)

## License & Credits

Created for GTNH community. Based on OpenComputers Space Pumping script located at https://wiki.gtnewhorizons.com/wiki/Open_Computers_Space_Pumping