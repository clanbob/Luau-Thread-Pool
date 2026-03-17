# Luau Thread Pool

A lightweight Luau/Roblox thread-pool module with two scheduling strategies:

- **DynamicPool**: grows workers on demand up to a configurable cap and falls back to an overload coroutine when saturated.
- **StaticPool**: pre-allocates a fixed number of workers and queues tasks while all workers are busy.

The module exports constructors for both pool types from `Thread.luau`.

## File

- `Thread.luau` — full implementation and exported types.
- Idle worker storage uses a LIFO stack internally, while pending static-pool event handlers remain FIFO in a queue.

## Setup

```luau
local ThreadPool = require(path.To.Thread)
```

---

## DynamicPool

### Create a pool

```luau
local pool = ThreadPool.DynamicPool(sizeCap, idleTime)
```

- `sizeCap` (`number`): maximum worker count (`>= 0`).
- `idleTime` (`number?`): optional idle cleanup interval in seconds (`>= 0`).

### Methods

- `pool:Spawn(fn, ...)`
  - Uses overload thread first (if present), otherwise uses an idle worker.
  - Creates a new worker if under `sizeCap`.
  - Creates/uses overload coroutine when capped and no idle workers exist.

- `pool:SpawnFromPool(fn, ...)`
  - Prioritizes idle/new worker allocation.
  - Falls back to overload coroutine only after pool capacity is exhausted.

- `pool:Reconcile()`
  - Pre-fills workers until `current_size == sizeCap`.

- `pool:AdjustSizeCap(newSizeCap)`
  - Updates cap and trims queued idle workers if the cap is lowered.

- `pool:GetCurrentSize()`
  - Returns current worker count.

- `pool:AdjustIdleTime(newIdleTime)`
  - Updates idle auditing interval used to reclaim idle workers/overload thread.

- `pool:Destroy()`
  - Destroys internal queues and clears pool state.

---

## StaticPool

### Create a pool

```luau
local pool = ThreadPool.StaticPool(size)
```

- `size` (`number`): number of workers to pre-create (`> 0`).

### Methods

- `pool:Spawn(fn, ...)`
  - Runs immediately on an idle worker if available.
  - If all workers are busy, queues a closure that captures arguments and runs later.

- `pool:Destroy()`
  - Schedules cleanup through the pool so queued work can drain before object teardown.
  - Ignores future `Spawn` calls during destruction.

---

## Examples

### Dynamic pool

```luau
local ThreadPool = require(path.To.Thread)

local pool = ThreadPool.DynamicPool(8, 10)

for i = 1, 20 do
    pool:Spawn(function(index)
        print("Dynamic task", index)
    end, i)
end

print("Current workers:", pool:GetCurrentSize())
pool:AdjustSizeCap(4)
pool:Destroy()
```

### Static pool

```luau
local ThreadPool = require(path.To.Thread)

local pool = ThreadPool.StaticPool(4)

for i = 1, 20 do
    pool:Spawn(function(index)
        print("Static task", index)
    end, i)
end

pool:Destroy()
```

---

## Notes

- Worker task execution is wrapped with `pcall`; runtime errors are emitted via `warn`.
- `DynamicPool` with `sizeCap == 0` effectively routes all work through overload behavior.
- This module is intended for Luau coroutine/task scheduling environments (for example, Roblox).
