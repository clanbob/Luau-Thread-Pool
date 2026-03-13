# Luau Thread Pool

A lightweight thread-pool module for Luau/Roblox that provides two pool strategies:

- **DynamicPool**: grows worker coroutines up to a cap and falls back to an overload coroutine when saturated.
- **StaticPool**: pre-allocates a fixed number of workers and queues tasks when all workers are busy.

The module returns a public table with constructors for both pool types.

## File

- `Thread.luau` — main implementation.

## API

## `DynamicPool`

Create with:

```luau
local ThreadPool = require(path.To.Thread)
local pool = ThreadPool.DynamicPool(sizeCap)
```

### Methods

- `pool:Spawn(fn, ...)`
  - Schedules `fn` with arguments.
  - Uses an idle worker if available.
  - Creates a new worker if below `sizeCap`.
  - Uses an overload coroutine if all workers are busy and cap reached.

- `pool:Destroy()`
  - Destroys internal queues and clears pool table.

---

## `StaticPool`

Create with:

```luau
local ThreadPool = require(path.To.Thread)
local pool = ThreadPool.StaticPool(size)
```

### Methods

- `pool:Spawn(fn, ...)`
  - Runs immediately on an idle worker when available.
  - If all workers are busy, enqueues the task for later execution.

- `pool:Destroy(cancelAllThreads: boolean)`
  - `true`: cancels idle worker coroutines immediately and cleans pool state.
  - `false`/`nil`: schedules deferred cleanup after queued work has been processed.

---

## Basic Examples

### Dynamic pool

```luau
local ThreadPool = require(path.To.Thread)

local pool = ThreadPool.DynamicPool(8)

for i = 1, 20 do
    pool:Spawn(function(index)
        print("Dynamic task", index)
    end, i)
end

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

-- graceful cleanup (lets queued work drain)
pool:Destroy(false)
```

## Notes

- Task functions should generally avoid long unbounded blocking behavior.
- Errors inside worker execution are handled via `pcall` in worker wrappers.
- This module is intended for Luau coroutine/task scheduling environments (e.g., Roblox).
