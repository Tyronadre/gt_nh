# MEDINA System Architecture

## Overview

MEDINA (Modular Extraction and Dispatch Intelligence Network Array) is a wireless automation system for GTNH Space Elevator mining.

**v1.5 (Current) — Broker MK3:** A single consolidated broker computer handles dispatch AND consumable loading for up to 6 local Mining Modules. A small **cooperative task scheduler** (`scheduler.lua`) runs each module's load as a coroutine, so all 6 load concurrently while the UI and telemetry stay live. Loads are self-pacing (database fingerprints confirmed by read-back) and route items by identity rather than slot position. Measured ~9.4× the throughput of the earlier blocking design (~100k → ~938k Infinity Catalyst dust/hr), validated over a 12-hour soak test.

**Evolution:** v0.x separated broker (dispatch) and job_node (consumables) across computers. v1.0 (Broker MK2) consolidated them but loaded modules sequentially with blocking sleeps, freezing the broker during each load. v1.5 (Broker MK3) keeps the consolidation but makes loading concurrent and non-blocking. The optional `job_node.lua` remote-worker path is retained for future multi-node fleets (the shared 81-slot MK3 database caps a fleet at 27 modules).

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MEDINA SYSTEM ARCHITECTURE                       │
└─────────────────────────────────────────────────────────────────────────┘

                          ┌──────────────────┐
                          │   BROKER NODE    │
                          │  MEDINA-Station  │
                          │  (3×2 T3 Screen) │
                          └────────┬─────────┘
                                   │
                 ┌─────────────────┼─────────────────┐
                 │                 │                 │
          Port 2026 (RX)    Port 2026 (RX)    Port 2026 (RX)
                 │                 │                 │
        ┌────────▼────────┐ ┌──────▼──────┐ ┌───────▼────────┐
        │  DUST TELEMETRY │ │ HW TELEMETRY│ │ FLUID TELEMETRY│
        │  dust_telem.lua │ │hw_telem.lua │ │fluid_telem.lua │
        │ (DUST_UPDATE)   │ │(HW_UPDATE)  │ │(FLUID_UPDATE)  │
        │  every 10s      │ │ every 10s   │ │  every 10s     │
        └────────┬────────┘ └──────┬──────┘ └───────┬────────┘
                 │                 │                 │
         ┌───────▼─────────────────▼─────────────────▼──────┐
         │        BROKER STATE AGGREGATION                  │
         │  • Dust levels (stock vs threshold)              │
         │  • Drone availability (all 14 tiers)             │
         │  • Drill kits (by material, tips+rods)           │
         │  • Plasma levels (all 5 tiers)                   │
         │  • Hardware health                               │
         └───────┬──────────────────────────────────────────┘
                 │
         ┌───────▼───────────────────────────────┐
         │   BATCH JOB DISPATCH                  │
         │  (Every 1 second)                     │
         │  • Get all idle modules               │
         │  • Build needs list (items < target)  │
         │  • For each module: assign next asteroid
         │  • Check drone availability           │
         │  • Check drill kit availability       │
         │  • Look up optimal distance           │
         └───────┬─────────────────────────────┘
                 │
      Port 2027 (TX broadcast)
                 │
         ┌───────▼──────────────────────────────────────────┐
         │            JOB NODES (1 to N)                    │
         │         job_node.lua × N instances               │
         │                                                  │
         │  ┌────────────────────────────────────────────┐  │
         │  │  JOB_NODE #1                               │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ MODULE #1 (MK-I/II/III Tier)        │   │  │
         │  │  │  • Receives MEDINA_COMMAND job      │   │  │
         │  │  │  • Loads drill tips & rods via ME   │   │  │
         │  │  │  • Loads drone via ME               │   │  │
         │  │  │  • Sends to Input Bus               │   │  │
         │  │  │  • Runs recipe at distance/OD       │   │  │
         │  │  │  • Recovers items via transposer    │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ MODULE #2 (parallel mining)         │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │  ┌─────────────────────────────────────┐   │  │
         │  │  │ ... up to 6 modules per node        │   │  │
         │  │  └─────────────────────────────────────┘   │  │
         │  │                                            │  │
         │  │ HW CONNECTIONS:                            │  │
         │  │  • ME Interface (item import/export)       │  │
         │  │  • Database (item fingerprints)            │  │
         │  │  • Transposer (item movement to bus)       │  │
         │  │  • Mining Module (recipe control)          │  │
         │  └────────────────────────────────────────────┘  │
         │                                                  │
         │  ┌────────────────────────────────────────────┐  │
         │  │  JOB_NODE #2 ... JOB_NODE #N (same setup)  │  │
         │  └────────────────────────────────────────────┘  │
         └──────────────────────────────────────────────────┘
                 │
        Port 2026 (TX Telemetry back to broker)
                 │
      ┌──────────▼──────────┐
      │  Status: IDLE/BUSY  │
      │  Modules: [jobs]    │
      │  Last seen: XX:XX   │
      └─────────────────────┘
```

## Component Specifications

### Broker Node (broker-mk3.lua)

**Purpose:** Central controller. Aggregates telemetry, selects mining targets, and drives up to 6 local Mining Modules — dispatching jobs and loading their consumables in one process.

**Hardware:**
- Tier 2 Wireless Network Card (strength 400)
- GPU + 3×2 T3 screen array
- Shared OC Database (3 slots per module)
- Per module: module-controller adapter, ME-interface adapter, transposer

**Supporting modules (on the same computer):**
- `scheduler.lua` — cooperative task engine (spawn / sleep / await / lock; one clock via `computer.uptime`)
- `target_editor.lua` — editor UI and atomic target-config persistence, normally hosted by the dust node
- `target_editor_app.lua` — optional legacy standalone editor
- `loader.lua` — per-module load sequence, run as a task; read-back confirmation + identity-based item routing
- `logger.lua` — configurable logging (file / console / Loki); disabled by default, ERROR/WARN to `/tmp/spacemining.log`

**Network:**
- **Inbound (Port 2026):** telemetry plus remote target-editor requests
- **Outbound (Port 2027):** optional remote job-node commands
- **Editor reply (Port 2028):** direct broker responses received by the editor computer

**State Tracked:**
- Dust levels (stock vs. thresholds), drone counts, drill kits, plasma levels — from telemetry
- Live module status (IDLE / LOADING / RUNNING / DONE / ERROR) and per-load diagnostics

**Dispatch Logic (drone-first, on a short interval):**
- Build a needs list (items below threshold) sorted by priority mode
- Compute availability = telemetry stock − drones/kits already committed to busy modules
- Iterate drones highest-tier first; assign a needed, drone-eligible asteroid that is under its per-asteroid cap of `floor(totalModules/2)+1`
- Each assignment spawns a concurrent cooperative load task; the dispatch loop never blocks

**Boot Configuration:**
- Priority mode prompt: "threshold" (lowest stock/target ratio first) or "rarity" (highest dust priority first, then ratio)
- (Plasma mode selection is not implemented; plasma is supplied by a hardware ME Fluid Export Bus.)
- Stop the broker with **Ctrl+Alt+C** in the OC console.

---

### Dust Telemetry Node (dust_telem.lua)

**Purpose:** Scans dust storage, broadcasts inventory levels, and hosts the
interactive stock-target editor.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU, display, and keyboard
- ME Controller or ME Interface (read-only access to dust storage)

**Network:**
- **Outbound (Port 2026):** Broadcasts chunked DUST_UPDATE payloads every 10 seconds
- Broadcasts the current target revision before each dust snapshot; the broker
  only persists it when the revision changes
- Payload: all registered mineable item names and current stock counts

**Exclusive UI modes:**
- The normal dashboard loop scans and publishes telemetry
- Pressing `T` returns from that loop and starts the editor-only 50 ms input loop
- Saving is local; closing the editor resumes telemetry and publishes the change

**Monitored Items:**
- All items in `config.dustTargets` are scanned so the broker can enable them at runtime
- Items enabled in `target_config.lua` are resolved into `config.conditions`
- Only items below threshold trigger mining jobs

---

### Hardware Telemetry Node (hw_telem.lua)

**Purpose:** Scans the drone and drill consumable inventory from the hardware-staging ME network, broadcasts availability to broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (dashboard display)
- OC Adapter on ME Controller (read-only access to hardware-staging ME network)

**Network:**
- **Outbound (Port 2026):** Broadcasts HW_UPDATE payload every 10 seconds
- Payload: drone counts (by tier key) and drill kit counts (tips ∩ rods by material)

**Inventory Scanning:**
- Calls `me_controller.getItemsInNetwork()` for all items
- Counts items with exact label match (e.g., "Mining Drone MK-VII", "Steel Drill Tip")
- Groups tips and rods by material to compute kits
- Drill kit = min(tips, rods) for that material
- Only reports non-zero counts to minimize payload

**Dashboard:**
- Left column: Drone availability (14 tiers, cyan when > 0)
- Right column: Drill kit availability (9 materials, magenta when available)
- Masking: Drills only displayed if any drone is in stock
- Updates every 10 seconds

**Role in Dispatch:**
- Broker uses these counts directly to decide whether `selectDrone()` can find an available drone
- These are the source of truth — no estimation or allocation tracking by broker

---

### Fluid Telemetry Node (fluid_telem.lua)

**Purpose:** Monitors plasma tank levels and broadcasts to broker.

**Hardware:**
- Tier 2 Wireless Network Card
- GPU (dashboard display)
- Fluid Tank or Fluid Transposer (reads plasma levels)

**Network:**
- **Outbound (Port 2026):** Broadcasts FLUID_UPDATE payload every 10 seconds
- Payload: plasma tank levels (mB) for all 5 plasma tiers

**Plasma Tiers Monitored:**
1. Helium Plasma
2. Bismuth Plasma
3. Radon Plasma
4. Technetium Plasma
5. Plutonium-241 Plasma

---

### Job Nodes (job_node.lua × N)

**Purpose:** Receive mining jobs from broker, load consumables from ME network, execute mining recipes on up to 6 Mining Modules, recover output.

**Hardware per Job Node:**
- Tier 2 Wireless Network Card
- ME Interface (imports/exports items)
- Database (stores item fingerprints)
- Transposer (moves items from ME Interface to Input Bus)
- Mining Modules (1 to 6 per node, each is a multiblock recipe machine)
- Input Bus (feeds items into Mining Modules)

**Network:**
- **Inbound (Port 2027):** Receives MEDINA_COMMAND jobs from broker
- **Outbound (Port 2026):** Sends status updates every 30s (self-registration + module status)

**Job Execution Pipeline:**
1. Receive job: `{ asteroid, drone, distance, drillKey, plasmaName, modulesInUse }`
2. For each module in job:
   - Query ME for drone item by name
   - Store drone fingerprint in database slot via `me_interface.store()`
   - Query ME for drill tips and rods (by material, 4× each per parallel)
   - Store drill fingerprints in database slots
   - Load drone into module via `iface.setInterfaceConfiguration()` + `transposer.transferItem()`
   - Load drills into module via same pipeline
   - Configure module: `setParameters(0, 0, distance)` and plasma mode
   - Run recipe until complete
   - Recover output back to ME via transposer
   - Clear interface config for next job

**Constraints:**
- All modules share a single ME Interface and transposer
- Item loads must be serialized per module to avoid cross-contamination
- Plasma is a hardware concern (ME Fluid Export Bus wired directly to Input Hatch)
- Draconic Core is hard-capped at 1 parallel regardless of module tier

---

## Data Flow Summary

| Component | Purpose | Port | Frequency | Direction |
|-----------|---------|------|-----------|-----------|
| **Broker MK3** | Central controller, UI, dispatch, drives local modules | 2026 in, 2027/2028 out | — | Receives telemetry/editor requests; loads/runs its own modules |
| **Dust Telem + Editor** | Monitors stocks; exclusively runs the editor when opened | 2026 in | 10s / after editor closes | → Broker |
| **HW Telem** | Scans drone/drill kit inventory | 2026 in | 10s | → Broker |
| **Fluid Telem** | Reads plasma tank levels | 2026 in | 10s | → Broker |
| **Job Nodes** | Execute mining jobs on modules | 2026 in, 2027 out | Per job | ← Broker commands, → Status updates |

---

## Network Protocols

### MEDINA_TELEMETRY (Inbound to Broker, Port 2026)

All telemetry nodes send updates in this format:

```lua
{
  protocol    = "MEDINA_TELEMETRY",
  sender      = "node-id",
  payloadType = "HW_UPDATE" | "DUST_UPDATE" | "FLUID_UPDATE",
  -- DUST_UPDATE also carries batchId, chunkIndex, and chunkCount.
  data        = { ... }
}
```

**HW_UPDATE** data:
```lua
{
  drones = { ["lv"]=2, ["mv"]=5, ... },
  drills = { ["steel"]=10, ["titanium"]=3, ... }
}
```

**DUST_UPDATE** data:
```lua
{
  ["Uranium 238 Dust"] = { stock=50000, threshold=0 },
  ["Plutonium 239 Dust"] = { stock=12000, threshold=10000000 },
  ...
}
```

The dust node splits one inventory snapshot into bounded chunks. The broker
waits until every chunk in a batch has arrived before dispatching against a
freshly edited target set.

**FLUID_UPDATE** data:
```lua
{
  ["Plutonium-241 Plasma"] = 500000,
  ["Technetium Plasma"] = 250000,
  ...
}
```

### MEDINA_TARGET_EDITOR (Dust Node → Broker, Port 2026)

The dust node broadcasts `TARGET_CONFIG_APPLY` before every dust snapshot.
These packets are fire-and-forget (`noReply=true`) and carry a content revision.
The broker validates, saves, and applies a revision once; repeated packets are
ignored. This reuses the proven telemetry route and recovers automatically from
a dropped broadcast. The optional standalone editor may still request a direct
result on port 2028.

### MEDINA_JOB (Job Node → Broker Status, Port 2026)

Job nodes send status updates:

```lua
{
  protocol    = "MEDINA_JOB",
  sender      = "node-id",
  nodeId      = "unique-node-name",
  modules     = { 
    { index=1, tier="MK-II", status="IDLE", job=nil },
    { index=2, tier="MK-II", status="RUNNING", job={...} },
    ...
  },
  lastSeen    = os.time()
}
```

### MEDINA_COMMAND (Broker → Job Nodes, Port 2027)

Broker broadcasts mining jobs:

```lua
{
  protocol = "MEDINA_COMMAND",
  target = "node-id",
  payloadType = "JOB_ASSIGN",
  data = {
    jobId = "unique-job-id",
    moduleIndex = 1,
    asteroid = "Uranium-Plutonium",
    droneKey = "uiv",
    drillKey = "tungstensteel",
    droneLocked = false,
    distance = 51,
    parallels = 8
  }
}
```

**Notes:**
- `target` specifies the node that should execute this job
- `droneLocked` is always false in current implementation (locking logic removed for simplicity)
- `parallels` is the max parallel count for the assigned module tier
- Distance is looked up from `config.optimizationMatrix` and clamped to 200

---

## Configuration

All mining parameters are defined in `config.lua`:

- **Asteroids:** Material compositions, size ranges, valid distance and drone tier ranges, computation and power requirements
- **Drones:** 14 tiers from MK-I (LV) to MK-XIV (MAX)
- **Drills:** 9 material tiers (Steel through Transcendent Metal)
- **Plasmas:** 5 tiers with consumption rates, time discounts, and size bonuses
- **Optimization Matrix:** Pre-computed optimal distances per [module tier][asteroid][drone tier]
- **Dust Targets:** Mapping of dust items to source asteroids and mining priorities
- **Conditions:** Dust threshold levels that trigger mining jobs

---

## Scaling Considerations

- **Job Nodes:** Add more job node instances to mine asteroids in parallel. Each node can control up to 6 modules but shares ME/transposer hardware, so throughput scales with the transposer speed and item loading latency.
- **Telemetry Nodes:** Multiple instances of dust_telem, hw_telem, or fluid_telem can exist for redundancy. Broker aggregates the latest update from each sender.
- **Wireless Range:** All nodes must be within 400 blocks (configurable via `modem.setStrength()`). Extend range or add relay nodes if needed.
- **ME Network:** All job nodes must have access to the same ME Controller for drone and drill sourcing. Plasma is hardware-direct (no network required).

---

## Future Roadmap

**MEDINA v2.0** (planned post-v1.0):
- MQTT fork: Replace wireless modem with MQTT broker for cloud-scale automation
- Internet Cards: Replace wireless modems with Internet Cards for better reliability
- Mosquitto broker on homelab server

