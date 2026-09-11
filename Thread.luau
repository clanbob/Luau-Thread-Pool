--[[
	THREAD

	Purpose:
		Thread pool:
			- Dymanic pool: grows and removes thread based on usage
			- Static pool: pre-allocates threads and reuses them, if pool is full it queues requests

	Dynamic cancellation:
		Capture worker = coroutine.running() and job_id = pool:GetWorkerJobId(worker)
		while the callback is active. Later call pool:CancelWorker(worker, job_id).
		Scope cleanup must call that method instead of directly cancelling the thread.
		Spawn / SpawnFromPool also return worker, job_id (the job may already be done).
		Passing job_id prevents stale cleanup from cancelling a reused worker's new job.
		Cancellation must come from another thread while the worker is suspended.
		With protect_threads=false, failed jobs are reaped by audits or ReapDeadWorkers().
		StaticPool behavior is unchanged.

	Author:
		TheRoyalDrew
]]




local coroutine_create = 	                                  coroutine.create
local coroutine_resume = 	                 coroutine.resume
local coroutine_running =   	coroutine.running
local coroutine_yield = 	       coroutine.yield

local task_spawn =  	task.spawn
local task_wait = 	        task.wait

local table_clear = 	           table.clear
local table_pack =    	table.pack
local table_unpack =	                 table.unpack

local math_clamp = 	  math.clamp
local os_clock = 	           os.clock





local Queue = { }
Queue.__index = Queue

function Queue.New(): Queue
	return setmetatable({
		items = {},

		first = 1,
		last = 1,
		size = 0
	}, Queue)
end

function Queue:Enqueue(item : any)
	self.items[self.last] = item
	self.last += 1

	self.size += 1

	return item
end

function Queue:Dequeue(): any
	if self.size <= 0 then return end

	local item = self.items[self.first]
	self.items[self.first] = nil

	self.size -= 1
	self.first += 1
	if self.size <= 0 then
		-- NOTE: prevents indexing forever, by reseting the indexes
		-- when there are no items left.
		self.first = 1
		self.last = 1
	end

	return item
end

function Queue:Destroy()
	table_clear(self.items)

	self.first = 1
	self.last = 1
	self.size = 0
end

function Queue:DropFront(amount: number): number
	if amount <= 0 or self.size <= 0 then return 0 end

	local removed = math.min(amount, self.size)
	local first = self.first
	local last_removed = first + removed - 1

	for index = first, last_removed do
		self.items[index] = nil
	end

	self.size -= removed
	self.first = last_removed + 1

	if self.size <= 0 then
		self.first = 1
		self.last = 1
	end

	return removed
end

local function run_event_handler_in_worker_thread(pool, fn, ...)
	if pool.protect_threads then
		local success, err = pcall(fn, ...)
		if not success then warn(`{err}`) end
		return
	end

	fn(...)
end



local DynamicPool = { }
DynamicPool.__index = DynamicPool

function DynamicPool:_DetermineThreadPoolUsage()
	if self.size_cap <= 0 then return  end

	local threads_not_in_use = self.threads.size
	if threads_not_in_use < self.threads_not_used_since_last_audit then
		self.threads_not_used_since_last_audit = threads_not_in_use
	end


	if self.current_size > 49 then
		warn('[DynamicPool] thread leak possible, current size: '..self.current_size..', max size: '..self.size_cap, 'audit time: '..self.idle_time)
	end
end

function DynamicPool:AdjustIdleTime(new_idle_time : number)
	if new_idle_time < 0 then error("Idle time must be greater than or equal 0") end
	if new_idle_time == self.idle_time then return end

	self.idle_time = new_idle_time

	if not self.is_auditing then
		self:_ScheduleWorkerAudit()
	end
end

function DynamicPool:_ScheduleWorkerAudit()
	if self.idle_time <= 0 then return end

	self.is_auditing = true
	task_spawn(function()
		while self.threads do
			if self.idle_time <= 0 then
				self.is_auditing = false
				break 
			end

			task_wait(self.idle_time)
			if not self.threads then return end

			self:ReapDeadWorkers()
			local time_snice_start = os_clock()

			local removed = self.threads:DropFront(self.threads_not_used_since_last_audit)
			self.current_size -= removed

			self.threads_not_used_since_last_audit = self.threads.size

			if self.overload_thread then
				if time_snice_start - self.used_overload_thread_time >= self.idle_time then
					self.overload_thread = nil
				end
			end
		end
	end)
end


function DynamicPool:GetWorkerJobId(worker: thread): number?
	if not self.active_workers then return nil end
	return self.active_workers[worker] or self.active_overload_threads[worker]
end

-- NOTE: Cancels active regular or overload workers. Idle/foreign workers are rejected.
-- expected_job_id only when the caller guarantees ownership of the current job.
function DynamicPool:CancelWorker(worker: thread, expected_job_id: number?): (boolean, string?)
	local regular_job = self.active_workers[worker]
	local job_id = regular_job or self.active_overload_threads[worker]
	
	if not job_id then return false end
	if expected_job_id ~= nil and expected_job_id ~= job_id then
		return false
	end

	local status = coroutine.status(worker)
	if status == "running" or status == "normal" then
		return false
	end

	if status ~= "dead" then
		local success, err = pcall(task.cancel, worker)
		if not success then return false end
	end

	if regular_job then
		self.active_workers[worker] = nil
		self.current_size -= 1
	else
		self.active_overload_threads[worker] = nil
	end

	return true
end

-- NOTE: Unprotected callback errors or direct task.cancel calls bypass completion.
function DynamicPool:AduitDeadWorkers(): number
	if not self.active_workers then return 0 end
	local removed = 0
	for worker in self.active_workers do
		if coroutine.status(worker) == "dead" then
			self.active_workers[worker] = nil
			self.current_size -= 1
			removed += 1
		end
	end
	
	for worker in self.active_overload_threads do
		if coroutine.status(worker) == "dead" then
			self.active_overload_threads[worker] = nil
			removed += 1
		end
	end
	return removed
end

function DynamicPool:_TakeIdleWorker(): thread?
	local worker = self.threads:Dequeue()
	while worker do
		if coroutine.status(worker :: thread) ~= "dead" then return worker end
		-- Recover an idle worker that was cancelled outside this API.
		self.current_size -= 1
		worker = self.threads:Dequeue()
	end
	return nil
end

function DynamicPool:_StartWorker(worker: thread, is_overload: boolean, fn, ...)
	self.next_job_id += 1
	local job_id = self.next_job_id

	if is_overload then
		self.overload_thread = nil
		self.active_overload_threads[worker] = job_id
		self.used_overload_thread_time = os_clock()
	else
		self.active_workers[worker] = job_id
	end

	-- Register before task.spawn: the callback can immediately start another job.
	task_spawn(worker, fn, ...)
	return worker, job_id
end

function DynamicPool:_CreateWorker()
	return coroutine_create(function()
		while true do
			run_event_handler_in_worker_thread(self, coroutine_yield())
			if not self.threads then return end -- checks if the pool is destroyed
			self.active_workers[coroutine_running()] = nil

			-- NOTE: we can kill threads if the size cap if reduced while they are running,
			-- we might not have removed all the threads yet because they arent in the queue
			if self.current_size > self.size_cap then
				self.current_size -= 1
				return
			end

			self.threads:Enqueue(coroutine_running())
		end
	end)
end

function DynamicPool:_RunOverLoad(fn, ...)
	local worker = coroutine_running()
	run_event_handler_in_worker_thread(self, fn, ...)
	if not self.threads then return end

	self.active_overload_threads[worker] = nil
	self.overload_thread = worker
end

function DynamicPool:_CreateOverLoadThread()
	return coroutine_create(function()
		while true do
			self:_RunOverLoad(coroutine_yield())
			if not self.threads then return end
		end
	end)
end

function DynamicPool.New(size_cap : number, idle_time : number): DynamicPool
	if size_cap == nil then size_cap = 0 end
	if size_cap < 0 then error("Size cap must be greater than or equal 0") end

	local self = setmetatable({
		threads = Queue.New(),

		overload_thread = nil, -- one cached idle overload runner
		active_workers = {}, -- [thread] = job ID; included in current_size
		active_overload_threads = {}, -- [thread] = job ID; not counted
		next_job_id = 0,
		size_cap = size_cap,


		idle_time = idle_time or 0,
		threads_not_used_since_last_audit = 0,
		used_overload_thread_time = os_clock(),
		is_auditing = false,
		protect_threads = false,

		current_size = 0,
	}, DynamicPool)

	self:_ScheduleWorkerAudit()
	return self
end

-- fills the pool with threads up to the cap
function DynamicPool:Reconcile()
	if self.size_cap <= 0 then return end
	if self.current_size >= self.size_cap then return end

	local difference = self.size_cap - self.current_size
	for i = 1, difference do
		local thread = self:_CreateWorker()
		coroutine_resume(thread)

		self.threads:Enqueue(thread)
		self.current_size += 1
	end
end

function DynamicPool:GetCurrentSize()
	return self.current_size
end

-- adjusts the size cap of the pool, if the new size cap is smaller than the current size
-- then it will remove the excess threads from the pool
function DynamicPool:AdjustSizeCap(new_size_cap : number)
	if new_size_cap < 0 then error("Size cap must be greater than or equal 0") end
	if new_size_cap == self.size_cap then return end

	self.size_cap = new_size_cap

	local difference = self.current_size - self.size_cap
	if difference > 0 then
		if self.threads.size >= difference then
			local removed = self.threads:DropFront(difference)

			self.current_size -= removed

			self.threads_not_used_since_last_audit = 
				math_clamp(self.threads_not_used_since_last_audit - removed, 0, self.size_cap :: number)
		else
			local removed = self.threads:DropFront(self.threads.size)
			self.current_size -= removed

			self.threads_not_used_since_last_audit = 0
		end
	end
end

-- Dips from the pool first, then uses an overload runner.
function DynamicPool:SpawnFromPool(fn, ...)
	if not self.threads then return nil, nil end

	if self.size_cap > 0 then
		local worker = self:_TakeIdleWorker()
		if worker then
			self:_DetermineThreadPoolUsage()
			return self:_StartWorker(worker, false, fn, ...)
		end

		if self.size_cap > self.current_size then
			worker = self:_CreateWorker()
			coroutine_resume(worker)
			-- Count before spawning so reentrant calls see the right size.
			self.current_size += 1
			return self:_StartWorker(worker, false, fn, ...)
		end
	end

	local worker = self.overload_thread
	if not worker or coroutine.status(worker) == "dead" then
		worker = self:_CreateOverLoadThread()
		coroutine_resume(worker)
	end
	return self:_StartWorker(worker, true, fn, ...)
end

-- Uses the cached overload runner first, then dips into the pool.
function DynamicPool:Spawn(fn, ...)
	if not self.threads then return nil, nil end

	local worker = self.overload_thread
	if worker and coroutine.status(worker) ~= "dead" then
		return self:_StartWorker(worker, true, fn, ...)
	end
	self.overload_thread = nil
	return self:SpawnFromPool(fn, ...)
end

function DynamicPool:Destroy()
	if not self.threads then return end
	self.threads:Destroy()
	-- Preserve the existing behavior: active callbacks may finish after destruction.
	table_clear(self.active_workers)
	table_clear(self.active_overload_threads)
	table_clear(self)
end

local StaticPool = { }
StaticPool.__index = StaticPool

function StaticPool:_CreateWorker(): thread
	return coroutine_create(function()
		while true do
			run_event_handler_in_worker_thread(self, coroutine_yield())

			if not self.threads then -- checks if destroyed
				return
			end

			local queued_task = self.event_handler_queue:Dequeue()
			while queued_task do
				run_event_handler_in_worker_thread(self, queued_task.fn, table_unpack(queued_task.args, 1, queued_task.args.n))

				if not self.event_handler_queue or not self.threads then -- checks if destroyed
					return
				end

				queued_task = self.event_handler_queue:Dequeue()
			end

			self.threads:Enqueue(coroutine_running())
		end
	end)
end

function StaticPool.New(size : number)
	if size <= 0 then error("Size must be greater than 0") end

	local self = setmetatable({
		event_handler_queue = Queue.New(),
		threads = Queue.New(),
		protect_threads = false,
	}, StaticPool)

	for i = 1, size do
		local thread = self:_CreateWorker()

		coroutine_resume(thread)
		self.threads:Enqueue(thread)
	end

	return self
end

function StaticPool:Spawn(fn, ...)
	if self.destroyed then return end

	local idle_thread = self.threads:Dequeue()
	if not idle_thread then
		-- NOTE: enqueue the function and packed args directly to avoid
		-- allocating one closure per queued spawn.
		self.event_handler_queue:Enqueue({
			fn = fn,
			args = table_pack(...)
		})

		return 
	end

	task_spawn(idle_thread, fn, ...)
end

function StaticPool:Destroy()
	if self.destroyed then return end

	local function clean()
		self.event_handler_queue:Destroy()       
		self.threads:Destroy()

		table_clear(self)
		setmetatable(self, nil)
		self = nil
	end

	-- NOTE: we spawn a thread, inside of the thread pool itself
	-- to ensure that all the event handlers have ran before we 
	-- destroy the pool
	self:Spawn(clean)

	-- NOTE: if self is return to us that means the clean
	-- thread has yielded, this flag prevents subsquent spawn 
	-- calls durning that window until the object gets cleaned
	if self then
		self.destroyed = true
	end
end

local Public = { }
Public.__index = Public

function Public.DynamicPool(size_cap : number, idle_time): DynamicPool
	return DynamicPool.New(size_cap, idle_time)
end

function Public.StaticPool(size : number): Pool
	return StaticPool.New(size)
end

export type Queue = {
	Enqueue: (self : Queue, item : any) -> any,
	Dequeue: (self : Queue) -> any,
	Destroy: (self : Queue) -> (),

	size : number
}

export type Pool = {
	Spawn: (self : Pool, fn : (...any) -> (), ...any) -> (),
	Destroy: (self : Pool) -> (),
	protect_threads: boolean
}

export type DynamicPool = {
	Spawn: (self: DynamicPool, fn: (...any) -> (), ...any) -> (thread?, number?),
	Destroy: (self: DynamicPool) -> (),
	protect_threads: boolean,
	active_workers: {[thread]: number},
	active_overload_threads: {[thread]: number},
	AdjustSizeCap: (self : DynamicPool, new_size_cap : number) -> (),
	Reconcile: (self : DynamicPool) -> (),
	SpawnFromPool: (self : DynamicPool, fn : (...any) -> (), ...any) -> (thread?, number?),
	GetCurrentSize: (self : DynamicPool) -> number,
	AdjustIdleTime: (self : DynamicPool, new_idle_time : number) -> (),
	CancelWorker: (self: DynamicPool, worker: thread, expected_job_id: number?) -> (boolean, string?),
	GetWorkerJobId: (self: DynamicPool, worker: thread) -> number?,
	ReapDeadWorkers: (self: DynamicPool) -> number,
}

return Public
