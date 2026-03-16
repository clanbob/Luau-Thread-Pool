--[[
	THREAD

	Purpose:
		Thread pool:
			- Dymanic pool: grows and removes thread based on usage
			- Static pool: pre-allocates threads and reuses them, if pool is full it queues requests

	Author:
		TheRoyalDrew
]]


-- Queue --

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
	table.clear(self.items)

	self.first = 1
	self.last = 1
	self.size = 0
end

local function run_event_handler_in_worker_thread(fn, ...)
	local success, err = pcall(fn, ...)

	if not success then warn(`{err}`) end
end



local DynamicPool = { }
DynamicPool.__index = DynamicPool

function DynamicPool:_DetermineThreadPoolUsage()
	if self.size_cap <= 0 then return  end

	local threads_not_in_use = self.threads.size
	if threads_not_in_use < self.threads_not_used_since_last_audit then
		self.threads_not_used_since_last_audit = threads_not_in_use
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
	task.spawn(function()
		while self.threads do
			if self.idle_time <= 0 then
				self.is_auditing = false
				break 
			end

			task.wait(self.idle_time)
			if not self.threads then return end

			local time_snice_start = os.clock()

			for i = 1, self.threads_not_used_since_last_audit do
				local thread = self.threads:Dequeue()
				if thread then
					self.current_size -= 1
				else
					break
				end
			end

			self.threads_not_used_since_last_audit = self.threads.size

			if self.overload_thread then
				if time_snice_start - self.used_overload_thread_time >= self.idle_time then
					self.overload_thread = nil
				end
			end


		end
	end)
end

function DynamicPool:_CreateWorker()
	return coroutine.create(function()
		while true do
			run_event_handler_in_worker_thread(coroutine.yield())
			if not self.threads then return end -- checks if the pool is destroyed

			-- NOTE: we can kill threads if the size cap if reduced while they are running,
			-- we might not have removed all the threads yet because they arent in the queue
			if self.current_size > self.size_cap then
				self.current_size -= 1
				return
			end

			self.threads:Enqueue(coroutine.running())
		end
	end)
end

function DynamicPool:_RunOverLoad(fn, ...)
	local cached_overload_runner = self.overload_thread
	self.overload_thread = nil

	run_event_handler_in_worker_thread(fn, ...)
	self.overload_thread = cached_overload_runner
end

function DynamicPool:_CreateOverLoadThread()
	return coroutine.create(function()
		while true do
			self:_RunOverLoad(coroutine.yield())
		end
	end)
end

function DynamicPool.New(size_cap : number, idle_time : number): DynamicPool
	if size_cap == nil then size_cap = 0 end
	if size_cap < 0 then error("Size cap must be greater than or equal 0") end

	local self = setmetatable({
		threads = Queue.New(),

		overload_thread = nil,
		size_cap = size_cap,


		idle_time = idle_time or 0,
		threads_not_used_since_last_audit = 0,
		used_overload_thread_time = os.clock(),
		is_auditing = false,

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
		coroutine.resume(thread)

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
			for i = 1, difference do
				self.threads:Dequeue()
			end

			self.current_size -= difference

			self.threads_not_used_since_last_audit = 
				math.clamp(self.threads_not_used_since_last_audit - difference, 0, self.size_cap :: number)
		else
			self.current_size -= self.threads.size

			local queue_size = self.threads.size
			for i = 1, queue_size do
				self.threads:Dequeue()
			end

			self.threads_not_used_since_last_audit = 0
		end
	end
end

-- dips from the pool first then overflows into the overload thread
function DynamicPool:SpawnFromPool(fn, ...)
	if self.size_cap > 0 then
		local thread = self.threads:Dequeue()
		if thread then
			task.spawn(thread, fn, ...)

			self:_DetermineThreadPoolUsage()
			return
		end

		if self.size_cap > self.current_size then
			local new_thread = self:_CreateWorker()

			coroutine.resume(new_thread)
			task.spawn(new_thread, fn, ...)

			self.current_size += 1
			return
		end
	end

	if not self.overload_thread then
		self.overload_thread = self:_CreateOverLoadThread()
		coroutine.resume(self.overload_thread)
	end

	task.spawn(self.overload_thread, fn, ...)
	self.used_overload_thread_time = os.clock()
end

-- uses the overloaded thread first then dips into the pool
-- if the overload thread is busy
function DynamicPool:Spawn(fn, ...)
	local runner_thread: thread

	if not self.overload_thread then
		local thread = self.threads:Dequeue()

		if thread then
			runner_thread = thread

			self:_DetermineThreadPoolUsage()
		elseif self.size_cap > self.current_size then
			local new_thread = self:_CreateWorker()
			coroutine.resume(new_thread)

			self.current_size += 1
			runner_thread = new_thread
		else
			self.overload_thread = self:_CreateOverLoadThread()
			coroutine.resume(self.overload_thread)

			runner_thread = self.overload_thread
		end
	else
		runner_thread = self.overload_thread   
	end

	if runner_thread == self.overload_thread then
		self.used_overload_thread_time = os.clock()
	end

	task.spawn(runner_thread, fn, ...)
end

function DynamicPool:Destroy()
	self.threads:Destroy()

	table.clear(self)
	setmetatable(self, nil)
end

local StaticPool = { }
StaticPool.__index = StaticPool

function StaticPool:_CreateWorker(): thread
	return coroutine.create(function()
		while true do
			run_event_handler_in_worker_thread(coroutine.yield())

			if not self.threads then -- checks if destroyed
				return
			end

			local event_handler = self.event_handler_queue:Dequeue()
			while event_handler do
				run_event_handler_in_worker_thread(event_handler)		
				
				if not self.event_handler_queue or not self.threads then -- checks if destroyed
					return
				end

				event_handler = self.event_handler_queue:Dequeue()
			end

			self.threads:Enqueue(coroutine.running())
		end
	end)
end

function StaticPool.New(size : number)
	if size <= 0 then error("Size must be greater than 0") end

	local self = setmetatable({
		event_handler_queue = Queue.New(),
		threads = Queue.New(),
	}, StaticPool)

	for i = 1, size do
		local thread = self:_CreateWorker()

		coroutine.resume(thread)
		self.threads:Enqueue(thread)
	end

	return self
end

function StaticPool:Spawn(fn, ...)
	if self.destroyed then return end

	local idle_thread = self.threads:Dequeue()
	if not idle_thread then
		local args = table.pack(...)
		-- NOTE: we enqueue functions which save the passed agruments
		-- thus we can dirctly run it, by passing the funciton
		self.event_handler_queue:Enqueue(function()
			fn(table.unpack(args, 1, args.n))
		end)

		return 
	end

	task.spawn(idle_thread, fn, ...)
end

function StaticPool:Destroy()
	if self.destroyed then return end

	local function clean()
		print(self.event_handler_queue.size)
		self.event_handler_queue:Destroy()       
		self.threads:Destroy()

		table.clear(self)
		setmetatable(self, nil)
	end

	-- NOTE: we spawn a thread, inside of the thread pool itself
	-- to ensure that all the event handlers have ran before we 
	-- destroy the pool
	self:Spawn(clean)

	-- NOTE: if self is return to as that means the clean
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
	Destroy: (self : Pool) -> ()
}

export type DynamicPool = Pool & {
	AdjustSizeCap: (self : DynamicPool, new_size_cap : number) -> (),
	Reconcile: (self : DynamicPool) -> (),
	SpawnFromPool: (self : DynamicPool, fn : (...any) -> (), ...any) -> (),
	GetCurrentSize: (self : DynamicPool) -> number,
	AdjustIdleTime: (self : DynamicPool, new_idle_time : number) -> ()
}

return Public
