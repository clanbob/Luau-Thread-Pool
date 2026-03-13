-- Queue System --

local Queue = { }
Queue.__index = Queue

function Queue.New()
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
end

function Queue:Find(item : any): boolean
    for _, item_in_queue in pairs(self.items) do
        if item_in_queue == item then return true end
    end

    return false
end

local function run_event_handler_in_worker_thread(fn, ...)
    local success, err = pcall(fn, ...)

    if not success then warn(`{err}`) end
end



local DynamicPool = { }
DynamicPool.__index = DynamicPool

function DynamicPool:_CreateWorker()
    return coroutine.create(function()
        while true do
            run_event_handler_in_worker_thread(coroutine.yield())
            if not self.threads then return end -- checks if the pool is destroyed
            
            self.threads:Enqueue(coroutine.running())
        end
    end)
end

function DynamicPool:_RunOverLoad(fn, ...)
    local cached_overload_runner = self.overload_thread
    self.overload_thread = nil

    fn(...)
    self.overload_thread = cached_overload_runner
end

function DynamicPool:_CreateOverLoadThread()
    return coroutine.create(function()
        while true do
            self:_RunOverLoad(coroutine.yield())
        end
    end)
end

function DynamicPool.New(size_cap : number)
    return setmetatable({
        threads = Queue.New(),

        overload_thread = nil,
        size_cap = size_cap,

        current_size = 0,
    }, DynamicPool)
end

function DynamicPool:Spawn(fn, ...)
    local thread = self.threads:Dequeue()
    if thread then
        task.spawn(thread, fn, ...)
        

        if self.overload_thread then
            self.overload_thread = nil
        end

        return
    end

    if self.size_cap > self.current_size then
        local new_thread = self:_CreateWorker()

        coroutine.resume(new_thread)
        task.spawn(new_thread, fn, ...)
        
        self.current_size += 1
        return
    end

    if not self.overload_thread then
        self.overload_thread = self:_CreateOverLoadThread()
        coroutine.resume(self.overload_thread)
    end

    task.spawn(self.overload_thread, fn, ...)
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
                
            local event_handler = self.event_handler_queue:Dequeue()
            while event_handler do

                run_event_handler_in_worker_thread(event_handler)
                event_handler = self.event_handler_queue:Dequeue() 
            end
            if self.destroyed then return end   
                
            self.threads:Enqueue(coroutine.running())
        end
    end)
end

function StaticPool.New(size : number)
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

function StaticPool:Destroy(cancel_all_threads : boolean)
    local function clean()
        self.event_handler_queue:Destroy()       
        self.threads:Destroy()

        table.clear(self)
        setmetatable(self, nil)
        self = nil
    end

    if cancel_all_threads then
        local thread = self.threads:Dequeue()
        while thread do
            task.cancel(thread)
            thread = self.threads:Dequeue()
        end
        
        clean()
        return
    end

    -- NOTE: we spawn a thread, inside of the thread pool itself
    -- to ensure that all the event handlers have ran before we 
    -- destroy the pool
    self:Spawn(clean)

    -- NOTE: if self is return to us without being nil, then the
    -- destroy thread has yielded, during that window we mark the pool 
    -- as destroyed, so that no more event handlers can be spawned
    if self then
        self.destroyed = true
    end
end

local Public = { }
Public.__index = Public

function Public.DynamicPool(size_cap : number)
    return DynamicPool.New(size_cap)
end

function Public.StaticPool(size : number)
    return StaticPool.New(size)
end

return Public


