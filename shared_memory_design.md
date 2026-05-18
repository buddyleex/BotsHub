# BotsHub Shared Memory Architecture

BotsHub implements a Windows named shared memory system for multibox coordination. The system enables up to 10 slave instances to coordinate with a central manager through three primary memory blocks.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BotsHub Multibox System                           │
│                        (Windows Named Shared Memory)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│          Manager (slot -1)                                                  │
│          ┌─────────────────────┐                                           │
│          │ - Launcher/control  │                                           │
│          │ - Create blocks     │                                           │
│          │ - Send commands     │                                           │
│          │ - Monitor events    │                                           │
│          └────────────┬────────┘                                           │
│                       │                                                     │
│          ┌────────────┼────────────┐                                       │
│          │            │            │                                       │
│    Local\BotsHub_AccountState  Inbox_0...9  Local\BotsHub_EventLog        │
│          │            │            │                                       │
│          ├────────────┼────────────┤                                       │
│          │            │            │                                       │
│     Slave0         Slave1       Slave2  ...Slave9                          │
│   (slot 0)       (slot 1)      (slot 2)        (slot 9)                   │
│   Every 150ms    Every 150ms   Every 150ms    Every 150ms                  │
│   publish        publish       publish         publish                     │
│   AccountState   AccountState  AccountState    AccountState                │
│                                                                              │
│   Every 1000ms   Every 1000ms  Every 1000ms   Every 1000ms                │
│   read inbox     read inbox    read inbox      read inbox                  │
│   execute cmds   execute cmds  execute cmds    execute cmds                │
│                                                                              │
│   Broadcast events to EventLog when game events occur                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component 1: AccountState Block

**Name:** `Local\BotsHub_AccountState`  
**Size:** 10 slots × ~256 bytes each ≈ 2.5 KB  
**Update Rate:** Every 150ms per slave  
**Access:** Slaves write their own slot; manager and slaves read all slots

The AccountState block publishes the current game state for each active slave instance. This enables the manager to monitor party status and allows slaves to maintain party awareness.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AccountState Block (10 slots × ~256 bytes each)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  SLOT 0                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ slaveIndex: 0         characterName: "Warrior1"   agentID: 1001     │  │
│  │ posX: -5000.5         posY: -4500.2              rotation: 45.0    │  │
│  │ healthPercent: 0.85   maxHealth: 400            energyPercent: 0.5 │  │
│  │ maxEnergy: 80         effects: 0x0001 (Weakness) modelState: 5     │  │
│  │ currentSkill: 123     targetAgentID: 2001       primary: 1         │  │
│  │ secondary: 8          level: 20                 isDead: 0          │  │
│  │ mapID: 152 (Underworld)  active: 1              lastUpdated: 12345 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  SLOT 1                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ slaveIndex: 1         characterName: "Ranger2"   agentID: 1002     │  │
│  │ posX: -5100.0         posY: -4400.0              rotation: 90.0    │  │
│  │ healthPercent: 0.90   maxHealth: 320            energyPercent: 0.6 │  │
│  │ maxEnergy: 60         effects: 0x0000           modelState: 1      │  │
│  │ currentSkill: -1      targetAgentID: 0          primary: 3         │  │
│  │ secondary: 10         level: 20                 isDead: 0          │  │
│  │ mapID: 152            active: 1                 lastUpdated: 12345 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  SLOT 2-9: (same structure, unused slots show zeros)                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Data Flow:
  Slave 0 (every 150ms) ──writes──> SLOT 0
  Slave 1 (every 150ms) ──writes──> SLOT 1
  Manager               ──reads all──> AccountState (decision logic)
  Slave N               ──reads other slots──> Party awareness
```

### AccountState Fields

| Field | Type | Purpose |
|-------|------|---------|
| slaveIndex | uint | Slot number (0-9) |
| characterName | string | Character name (UI display) |
| agentID | uint | Guild Wars agent ID |
| posX, posY | float | Current position in game world |
| rotation | float | Character facing angle |
| healthPercent | float | Health as 0.0-1.0 ratio |
| maxHealth | uint | Maximum health points |
| energyPercent | float | Energy as 0.0-1.0 ratio |
| maxEnergy | uint | Maximum energy points |
| effects | bitmask | Active effects/conditions |
| modelState | uint | Animation state |
| currentSkill | uint | Currently cast skill ID (-1 if none) |
| targetAgentID | uint | Current target (0 if none) |
| primary, secondary | uint | Equipped weapon sets |
| level | uint | Character level |
| isDead | bool | Death status |
| mapID | uint | Current map ID |
| active | bool | Slot in use |
| lastUpdated | uint | Timestamp of last update |

---

## Component 2: Inbox Blocks

**Name:** `Local\BotsHub_Inbox_{slaveIndex}` (per-slave)  
**Size:** 8 messages × ~64 bytes each ≈ 512 bytes per slave  
**Managed by:** Manager (writes); Slaves (read and execute)  
**Polling Rate:** Every 1000ms per slave

Each slave has a dedicated inbox for receiving commands from the manager. Commands are enqueued, executed, and cleared by the slave.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Inbox Block per Slave (8 messages × ~64 bytes each)                        │
│  One separate block for each of 10 slaves                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Local\BotsHub_Inbox_0                                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Index   Command        Param1        Param2        Active    Sender  │  │
│  ├──────────────────────────────────────────────────────────────────────┤  │
│  │  [0]     MOVE_TO        -5000         -4500         1 (pending) -1   │  │
│  │  [1]     (empty)        0             0             0          0     │  │
│  │  [2]     ATTACK_TARGET  2001          0             1 (pending) -1   │  │
│  │  [3]     (empty)        0             0             0          0     │  │
│  │  [4]     (empty)        0             0             0          0     │  │
│  │  [5]     (empty)        0             0             0          0     │  │
│  │  [6]     (empty)        0             0             0          0     │  │
│  │  [7]     (empty)        0             0             0          0     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Local\BotsHub_Inbox_1                                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Index   Command        Param1        Param2        Active    Sender  │  │
│  ├──────────────────────────────────────────────────────────────────────┤  │
│  │  [0]     TRAVEL_TO_MAP  193 (Cavalon) 0             1 (pending) -1   │  │
│  │  [1]     (empty)        0             0             0          0     │  │
│  │  [2]     (empty)        0             0             0          0     │  │
│  │  [...rest empty...]                                                    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Local\BotsHub_Inbox_2...9: (same pattern)                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Data Flow:
  Manager               ──writes command to SLOT 0──> Local\BotsHub_Inbox_0
  Manager               ──writes command to SLOT 1──> Local\BotsHub_Inbox_1
  Slave 0 (every 1000ms)──reads own inbox──> execute & clear
  Slave 1 (every 1000ms)──reads own inbox──> execute & clear
```

### Supported Commands

| Command | Parameters | Description |
|---------|------------|-------------|
| MOVE_TO | x, y | Move slave to coordinates |
| TRAVEL_TO_MAP | mapID | Travel to specified map |
| FOLLOW_LEADER | — | Follow leader (slot 0) |
| ATTACK_TARGET | agentID, skillID | Attack target agent |
| USE_SKILL | skillID, targetID | Cast skill on target |
| STOP | — | Cancel current action |
| RESURRECT | — | Cast resurrection spell |
| PICK_UP_LOOT | — | Pick up nearby items |
| INVITE_TO_PARTY | — | Invite target player |
| CUSTOM | varies | Custom farm-specific command |

---

## Component 3: EventLog Block

**Name:** `Local\BotsHub_EventLog`  
**Size:** 32 entries × ~32 bytes each ≈ 1 KB  
**Structure:** Circular buffer (oldest entries overwritten when full)  
**Access:** All slaves write events; manager and slaves read events

The EventLog provides a system-wide event stream for important game events. Processes maintain their own read cursor to retrieve only new events since the last poll.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  EventLog Block (32 entries × ~32 bytes each, circular buffer)              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Write Index (oldest) ────────────────> Read Cursor ──────────> Write Index │
│                                                                   (newest)   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Idx  EventType    Slot  Timestamp   Param1        Param2            │  │
│  ├──────────────────────────────────────────────────────────────────────┤  │
│  │ [0]  SKILL_CAST   1     12340000    targetID=2001 skillID=7        │  │
│  │ [1]  DEATH        0     12341000    agentID=1001  0                │  │
│  │ [2]  RESURRECT    2     12342000    targetID=1001 0                │  │
│  │ [3]  LOOT         1     12343000    itemCount=3   goldAmount=50    │  │
│  │ [4]  SKILL_CAST   0     12344000    targetID=2005 skillID=12       │  │
│  │ [5]  MAP_CHANGE   1     12345000    mapID=193     0                │  │
│  │ [6]  DEATH        2     12346000    agentID=1003  0                │  │
│  │ [7]  (empty)      0     0           0             0                │  │
│  │ ...                                                                  │  │
│  │ [31] (empty)      0     0           0             0                │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Once [31] filled, next event overwrites [0] and indices roll             │
│  Each process maintains own read cursor to track new events               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

Data Flow:
  Slave 0  ──writes event──> EventLog[N]
  Slave 1  ──writes event──> EventLog[N+1]
  Manager  ──polls every 1s──> ReadNewEvents() returns events since last read
  Slave 2  ──polls every 1s──> ReadNewEvents() returns events since last read
```

### Event Types

| Event Type | Description | Param1 | Param2 |
|-----------|-------------|--------|--------|
| SKILL_CAST | Slave cast skill | target agentID | skill ID |
| DEATH | Slave or target died | agent ID | — |
| KILL | Slave killed target | target agentID | — |
| RESURRECT | Slave resurrected teammate | target agentID | — |
| LOOT | Slave picked up loot | item count | gold amount |
| MAP_CHANGE | Slave changed maps | map ID | — |
| LOW_HEALTH | Slave health below threshold | agent ID | health % |
| PARTY_WIPE | All slaves died (raid wipe) | count | — |

---

## Implementation Notes

- **Polling rates:** AccountState updates every 150ms per slave; Inbox commands polled every 1000ms per slave
- **Thread safety:** Using Windows named shared memory handles; WriteProcessMemory synchronization handled by slot assignment
- **Scalability:** Fixed at 10 slave slots (sufficient for GW multibox boxing); expandable architecture
- **Circular buffer:** EventLog contains last 32 events; older events are overwritten
- **Command queueing:** Up to 8 pending commands per slave; additional writes are dropped if queue full
