--!nonstrict

local WorkflowOrchestratorService = {}
WorkflowOrchestratorService.__index = WorkflowOrchestratorService

export type Context = { [any]: any }
export type WorkflowStep = {
	id: string,
	action: (Context) -> any,
	rollback: ((Context) -> ())?,
	condition: ((Context) -> boolean)?,
	timeout: number?,
	retries: number?
}

local function DeepCopy(orig: any, visited: { [any]: any }?): any
	local orig_type = type(orig)
	local copy
	
	if orig_type == 'table' then
		visited = visited or {}
		
		if visited[orig] then
			return visited[orig]
		end
		
		copy = {}
		visited[orig] = copy
		
		for orig_key, orig_value in pairs(orig) do
			copy[DeepCopy(orig_key, visited)] = DeepCopy(orig_value, visited)
		end
		
		local mt = getmetatable(orig)
		if mt then
			setmetatable(copy, DeepCopy(mt, visited))
		end
	else 
		copy = orig
	end
	return copy
end

local Logger = {}
Logger.__index = Logger

function Logger.new()
	return setmetatable({}, Logger)
end

function Logger:Info(msg, data)
	print(string.format("[INFO] %s | Data: %s", msg, data and game:GetService("HttpService"):JSONEncode(data) or "nil"))
end

function Logger:Warn(msg, data)
	warn(string.format("[WARN] %s | Data: %s", msg, data and game:GetService("HttpService"):JSONEncode(data) or "nil"))
end

function Logger:Error(msg, data)
	warn(string.format("[ERROR] %s | Data: %s", msg, data and game:GetService("HttpService"):JSONEncode(data) or "nil"))
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _bindable = Instance.new("BindableEvent") }, Signal)
end

function Signal:Connect(callback)
	return self._bindable.Event:Connect(callback)
end

function Signal:Fire(...)
	self._bindable:Fire(...)
end

function Signal:Destroy()
	self._bindable:Destroy()
end

local Promise = {}
Promise.__index = Promise

local PROMISE_Status = {
	Pending = "Pending",
	Resolved = "Resolved",
	Rejected = "Rejected"
}

function Promise.new(executor)
	local self = setmetatable({
		_status = PROMISE_Status.Pending,
		_value = nil,
		_callbacks = {}
	}, Promise)

	local function resolve(val: any?)
		if self._status ~= PROMISE_Status.Pending then return end
		self._status = PROMISE_Status.Resolved
		self._value = val
		for _, cb in ipairs(self._callbacks) do
			if cb.onFulfilled then task.spawn(cb.onFulfilled, val) end
		end
	end

	local function reject(err)
		if self._status ~= PROMISE_Status.Pending then return end
		self._status = PROMISE_Status.Rejected
		self._value = err
		for _, cb in ipairs(self._callbacks) do
			if cb.onRejected then task.spawn(cb.onRejected, err) end
		end
	end

	task.spawn(function()
		local success, err = pcall(function()
			executor(resolve, reject)
		end)
		if not success then reject(err) end
	end)

	return self
end

function Promise.resolve(val)
	return Promise.new(function(resolve) resolve(val) end)
end

function Promise.reject(val)
	return Promise.new(function(_, reject) reject(val) end)
end

function Promise.delay(seconds)
	return Promise.new(function(resolve)
		task.wait(seconds)
		resolve(nil)
	end)
end

function Promise:andThen(onFulfilled, onRejected)
	return Promise.new(function(resolve, reject)
		local function handle(callback, val)
			local success, result = pcall(function()
				if type(callback) == "function" then
					return callback(val)
				else
					return val
				end
			end)

			if not success then
				reject(result)
			elseif type(result) == "table" and result.andThen then 
				result:andThen(resolve, reject)
			else
				resolve(result)
			end
		end

		local function successHandler(val)
			if onFulfilled then handle(onFulfilled, val) else resolve(val) end
		end

		local function errorHandler(err)
			if onRejected then handle(onRejected, err) else reject(err) end
		end

		if self._status == PROMISE_Status.Resolved then
			task.spawn(successHandler, self._value)
		elseif self._status == PROMISE_Status.Rejected then
			task.spawn(errorHandler, self._value)
		else
			table.insert(self._callbacks, { onFulfilled = successHandler, onRejected = errorHandler })
		end
	end)
end

function Promise:catch(onRejected)
	return self:andThen(nil, onRejected)
end

function Promise.race(promises)
	return Promise.new(function(resolve, reject)
		local finished = false
		for _, p in ipairs(promises) do
			local promiseObj = p :: any 
			promiseObj:andThen(function(val)
				if not finished then finished = true; resolve(val) end
			end, function(err)
				if not finished then finished = true; reject(err) end
			end)
		end
	end)
end

function WorkflowOrchestratorService.new()
	local self = setmetatable({}, WorkflowOrchestratorService)
	self._logger = Logger.new()
	
	self.StepStarted = Signal.new()
	self.StepCompleted = Signal.new()
	self.StepFailed = Signal.new()
	self.WorkflowStarted = Signal.new()
	self.WorkflowPaused = Signal.new()
	self.WorkflowResumed = Signal.new()
	self.WorkflowCompleted = Signal.new()
	self.WorkflowFailed = Signal.new()
	
	self._steps = {} :: {WorkflowStep}
	self._context = {}
	self._currentIndex = 0
	self._paused = false
	self._isRunning = false
	self._rollbacks = {}
	
	self._mainResolve = nil
	self._mainReject = nil
	
	return self
end

function WorkflowOrchestratorService:AddStep(step: WorkflowStep)
	assert(type(step) == "table", "Step must be a table")
	assert(type(step.id) == "string", "Step must have string id")
	assert(type(step.action) == "function", "Step must have action function")

	for _, existing in ipairs(self._steps) do
		assert(existing.id ~= step.id, "Step ID already exists: " .. step.id)
	end

	table.insert(self._steps, step)
	self._logger:Info("Added workflow step", { StepId = step.id })
end

function WorkflowOrchestratorService:GetSteps()
	return DeepCopy(self._steps)
end

function WorkflowOrchestratorService:_runStep(step: WorkflowStep)
	self._logger:Info("Running step", { StepId = step.id })
	self.StepStarted:Fire(step.id, self._context)

	if step.condition and not step.condition(self._context) then
		self._logger:Info("Skipping step due to condition", { StepId = step.id })
		return Promise.resolve(nil)
	end

	local function tryAction(attempt)
		local promise = step.action(self._context)
		
		if not (promise and type(promise) == "table" and promise.andThen) then
			promise = Promise.resolve(promise)
		else
			promise = promise :: any
		end

		if step.timeout then
			promise = Promise.race({
				promise,
				Promise.delay(step.timeout):andThen(function()
					return Promise.reject("Step '" .. step.id .. "' timed out after " .. tostring(step.timeout) .. " seconds")
				end)
			})
		end

		return promise:catch(function(err)
			if step.retries and attempt < step.retries then
				self._logger:Warn("Step failed, retrying", { StepId = step.id, Attempt = attempt + 1 })
				return tryAction(attempt + 1)
			end
			return Promise.reject(err)
		end)
	end

	return tryAction(0)
		:andThen(function(result)
			self._logger:Info("Step succeeded", { StepId = step.id })
			self.StepCompleted:Fire(step.id, result, self._context)
			
			if step.rollback then
				table.insert(self._rollbacks, function()
					self._logger:Info("Running rollback for step", { StepId = step.id })
					local success, err = pcall(function() 
						if step.rollback then step.rollback(self._context) end 
					end)
					if not success then
						self._logger:Warn("Rollback error", { StepId = step.id, Error = err })
					end
				end)
			end
			return result
		end)
		:catch(function(err)
			self.StepFailed:Fire(step.id, err)
			self._logger:Error("Step failed", { StepId = step.id, Error = err })
			return Promise.reject(err)
		end)
end

function WorkflowOrchestratorService:_processQueue()
	if self._paused then
		self._logger:Info("Workflow paused at step " .. tostring(self._currentIndex))
		self.WorkflowPaused:Fire(self._currentIndex)
		return
	end

	if self._currentIndex > #self._steps then
		self._logger:Info("Workflow completed successfully")
		self._isRunning = false
		self.WorkflowCompleted:Fire(self._context)
		
		if self._mainResolve then
			self._mainResolve(self._context)
		end
		return
	end

	local step = self._steps[self._currentIndex]

	self:_runStep(step)
		:andThen(function()
			if not self._isRunning then return end
			self._currentIndex = self._currentIndex + 1
			self:_processQueue()
		end)
		:catch(function(err)
			self._logger:Warn("Workflow error, initiating rollback", { Error = err })
			self._isRunning = false
			self.WorkflowFailed:Fire(err, self._context)
			
			self:_rollback():andThen(function()
				if self._mainReject then
					self._mainReject(err)
				end
			end)
		end)
end

function WorkflowOrchestratorService:Run(context)
	assert(not self._isRunning, "Workflow already running")
	
	self._isRunning = true
	self._paused = false
	self._context = context or {}
	self._currentIndex = 1
	self._rollbacks = {}

	self._logger:Info("Workflow started")
	self.WorkflowStarted:Fire(self._context)

	return Promise.new(function(resolve, reject)
		self._mainResolve = resolve
		self._mainReject = reject
		
		self:_processQueue()
	end)
end

function WorkflowOrchestratorService:Pause()
	if not self._isRunning then return false end
	if self._paused then return false end
	
	self._paused = true
	return true
end

function WorkflowOrchestratorService:Resume()
	if not self._paused then
		self._logger:Warn("Cannot resume; workflow not paused")
		return false
	end
	
	self._paused = false
	self._logger:Info("Workflow resumed from step " .. tostring(self._currentIndex))
	self.WorkflowResumed:Fire(self._currentIndex)
	
	self:_processQueue()
	
	return true
end

function WorkflowOrchestratorService:Abort(reason)
	if not self._isRunning then return end
	
	self._logger:Warn("Workflow aborted", { Reason = reason or "No reason" })
	self._paused = true
	self._isRunning = false
	
	if self._mainReject then
		self._mainReject(reason or "Aborted")
	end
end

function WorkflowOrchestratorService:_rollback()
	self._logger:Info("Starting rollback of executed steps")
	local promise = Promise.resolve(nil)

	for i = #self._rollbacks, 1, -1 do
		local rollbackFunc = self._rollbacks[i]
		promise = promise:andThen(function()
			return Promise.new(function(resolve)
				local ok, err = pcall(rollbackFunc)
				if not ok then
					self._logger:Warn("Rollback function error", { Error = err })
				end
				resolve(nil)
			end)
		end)
	end

	return promise:andThen(function()
		self._logger:Info("Rollback complete")
		self._rollbacks = {}
	end)
end

function WorkflowOrchestratorService:Reset()
	self._steps = {}
	self._context = {}
	self._currentIndex = 0
	self._paused = false
	self._isRunning = false
	self._rollbacks = {}
	self._logger:Info("Workflow reset")
end

function WorkflowOrchestratorService:Destroy()
	self.StepStarted:Destroy()
	self.StepCompleted:Destroy()
	self.StepFailed:Destroy()
	self.WorkflowStarted:Destroy()
	self.WorkflowPaused:Destroy()
	self.WorkflowResumed:Destroy()
	self.WorkflowCompleted:Destroy()
	self.WorkflowFailed:Destroy()
	self._logger:Info("WorkflowOrchestratorService destroyed")
end

return WorkflowOrchestratorService