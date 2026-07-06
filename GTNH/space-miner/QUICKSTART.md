# MEDINA — Quick Start

Automated Space Elevator mining for **GregTech: New Horizons**, running on
**OpenComputers**. Tell it what dusts to keep stocked; it mines them for you
across up to 6 Mining Modules at once.

This is the fast, friendly guide. For the full technical details see
[README.md](README.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

---

## What you need

**The broker computer (the brain — one of these runs everything):**
- An OpenComputers computer — Tier 3 is comfortable. For lots of modules, use a
  server in a rack with a component bus (each module uses component slots).
- Tier 2 Wireless Network Card
- GPU + screen (a 3-wide × 2-tall screen array is ideal, but start with anything)
- **One OpenComputers Database upgrade** — shared by all modules. A basic one
  covers 6 modules; a Tier 3 covers up to 27.

**Each Mining Module needs three OpenComputers parts:**
1. An **Adapter** touching the Mining Module's controller
2. An **Adapter** touching that module's **ME Interface**
3. A **Transposer** between that ME Interface and the module's **Input Bus**

> Pattern to remember: **Module adapter · Interface adapter · Transposer** — three
> parts per module, every time.

**Also:** plasma overdrive (if you use it) is supplied by *your own* ME Fluid
Export Bus into each module's input hatch. MEDINA does not handle plasma.

---

## 1. Install

### Easy way — the installer (recommended)

On each computer (needs an Internet Card), grab the installer and run it:

```
wget https://raw.githubusercontent.com/novashep/GTNH/main/space-miner/install-medina.lua /home/install-medina.lua
install-medina
```

It asks what the computer is (broker / telemetry node / remote job node /
target editor / everything) and downloads only the files that role needs. Run
it once per computer, picking the matching role each time.

### Manual way

If you'd rather pull files by hand, download them into `/home/`. Replace
`RAW_BASE` with this repo's raw path.

**On the broker computer:**

```
wget RAW_BASE/broker-mk3.lua            /home/broker-mk3.lua
wget RAW_BASE/scheduler.lua             /home/scheduler.lua
wget RAW_BASE/loader.lua                /home/loader.lua
wget RAW_BASE/config.lua                /home/config.lua
wget RAW_BASE/target_config.lua         /home/target_config.lua
wget RAW_BASE/target_editor.lua         /home/target_editor.lua
wget RAW_BASE/logger.lua                /home/logger.lua
wget RAW_BASE/list_components.lua       /home/list_components.lua
wget RAW_BASE/detect_module.lua         /home/detect_module.lua
wget RAW_BASE/job_node_config.example.lua /home/job_node_config.lua
```

**On the dust monitor node (required):**

```
wget RAW_BASE/config.lua    /home/config.lua
wget RAW_BASE/target_config.lua /home/target_config.lua
wget RAW_BASE/dust_telem.lua /home/dust_telem.lua
wget RAW_BASE/target_editor.lua /home/target_editor.lua
```

**On the hardware monitor node (required):**

```
wget RAW_BASE/config.lua  /home/config.lua
wget RAW_BASE/target_config.lua /home/target_config.lua
wget RAW_BASE/hw_telem.lua /home/hw_telem.lua
```

**On the plasma/fluid monitor node (required):**

```
wget RAW_BASE/config.lua    /home/config.lua
wget RAW_BASE/target_config.lua /home/target_config.lua
wget RAW_BASE/fluid_telem.lua /home/fluid_telem.lua
```

> ⚠️ The broker will **not mine** until **all three** monitor nodes are reporting
> in — it sits at "Waiting for telemetry..." until then. Dust tells it what to
> mine, hardware tells it what drones/kits you have, and fluid tells it you have
> plasma — and **mining modules physically can't run without a plasma fluid**, so
> all three are required.
>
> On each telem node, set `targetSide` near the top of the script to the side of
> its adapter facing the right ME Controller (dust → dust storage, hardware →
> drones/drill bits, fluid → your plasma network), then run it and leave it going.

---

## 2. Choose what to mine

Open `/home/target_config.lua`. This is your shopping list and is kept separate
from the large project configuration, so installer updates do not overwrite it.

Choose the default ME item-cell size and safety reserve:

```lua
targets.currentCellType = "16384k"
targets.cellCount = 1
targets.safetyMargin = 0.20
targets.maxTargetOverride = 0
targets.keepAllMinedItems = false
```

With these settings, every default item target is 80% of one `16384k` cell:
106,535,321 items. Then choose the items:

```lua
targets.items = {
  ["Diamond"]       = true,   -- use the default cell target
  ["Tungsten Dust"] = "10m",  -- absolute target
  ["Nether Star"]   = false,  -- disabled
}
```

- An item name must match the in-game name and `config.dustTargets` **exactly**.
- `true` uses the default cell target; `false` disables the item.
- A quantity such as `"50m"` or `"5k"` is an absolute target.
- `{ cellType="4096k", cellCount=2, safetyMargin=0.10 }` gives one item its own
  cell calculation. `{ target="50m", priority=1 }` combines an absolute target
  with a Rarity-mode priority.
- Cell capacities assume one item type per cell. Use lower targets if multiple
  item types share the same physical cell.
- Set `keepAllMinedItems = true` to enable all items from `config.dustTargets`.
  The `items` table remains an override list, so `["Coal Dust"] = false` excludes
  one item even in keep-all mode.

MEDINA already knows which asteroid produces each common dust, which drones can
mine it, and the best distance to use (in the `dustTargets`, asteroid, and
optimization sections — you usually don't need to touch those).

On the dust monitor, run `dust_telem` and press **T** or **F4**. Use **Space**
to toggle an item, **Enter** to edit its target, and **Ctrl+S** to validate and
save it. The insertion position blinks and supports Left/Right, Home/End,
Backspace, and Delete. Press **Esc** to close the editor, resume telemetry, and
publish the saved targets to the broker. The editor and telemetry loops never
run at the same time.

---

## 3. Tell it about your modules

Open `/home/job_node_config.lua`. At the top, set:
- `nodeId` — any name you like
- `dbAddr` — the address of your shared Database component

To find addresses, run:

```
list_components
```

Then add your modules **one at a time** with the helper:

1. Hook up one module's three parts (module adapter, interface adapter, transposer).
2. Run:
   ```
   detect_module
   ```
3. It finds the three new components, shows the proposed module, and asks you to
   confirm. Type `y`.
4. **Verify the two side numbers** it shows (`interfaceSide` / `inputBusSide`). It
   copies these from your previous module as a guess — correct them if this module
   faces a different direction.
5. Repeat for each module: **hook up → `detect_module` → verify → confirm.**

---

## 4. Run it

```
broker-mk3
```

It asks for a **priority mode**:
- **Threshold** — mines whatever is furthest below its target first. Keeps
  everything topped up evenly. (Good default.)
- **Rarity** — mines by the priority numbers in the config first. Use this if a
  few items matter much more than the rest.

Then the dashboard appears:
- **Left** — your modules and what each is doing (IDLE / LOADING / RUNNING).
- **Middle** — your dust list with fill %. A `!` means it's below target and being
  worked on.
- **Right** — drones in stock, drill kits, and the next asteroid up.

To stop the broker: **Ctrl+Alt+C** in the console.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| A dust sits at **0%** forever | `itemName` doesn't exactly match the in-game name. Fix spelling/capitalization. |
| A module shows **ERROR** | It auto-recovers in ~10s and retries. Every load is verified before the machine runs, so it never mines with the wrong gear. |
| A module just **waits / never loads** | You may have no drone in that asteroid's tier range, or no matching drill kit. Check the right panel. |
| Stuck on **"Waiting for telemetry..."** | The broker needs ALL THREE telem nodes (dust, hardware, fluid) reporting before it dispatches. Make sure all three telem computers are running and each `targetSide` is correct. |
| Edited targets do not appear on broker | Save with Ctrl+S and close the editor with Esc. Confirm the dust dashboard says `TARGET CONFIG: sent with telemetry`; the broker applies changed revisions received on port 2026. |
| Dashboard shows **"NO PLASMA - MINING BLOCKED"** | Modules can't run without a plasma fluid. Make sure you have one of the supported plasmas (Helium / Bismuth / Radon / Technetium / Plutonium-241) and that it's piped into each module's input hatch. |
| Want to see what's happening | Logging is off by default; set `config.logging.enabled = true` in `config.lua`. Logs go to `/tmp/spacemining.log`. |

---

## Want more?

- **Scaling past one computer's component limit** — the optional `job_node.lua`
  remote-worker path. The shared database caps a fleet at 27 modules.

MIT licensed. Built for the GTNH community — happy mining.
