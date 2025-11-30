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

local function DeepCopy(orig: any): any
	local orig_type = type(orig)
	local copy
	if orig_type == 'table' then
		copy = {}
		for orig_key, orig_value in pairs(orig) do
			copy[DeepCopy(orig_key)] = DeepCopy(orig_value)
		end

		local mt = getmetatable(orig)
		if mt then
			setmetatable(copy, DeepCopy(mt))
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
			if onFulfilled then
				handle(onFulfilled, val)
			else
				resolve(val)
			end
		end

		local function errorHandler(err)
			if onRejected then
				handle(onRejected, err)
			else
				reject(err)
			end
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
				if not finished then
					finished = true
					resolve(val)
				end
			end, function(err)
				if not finished then
					finished = true
					reject(err)
				end
			end)
		end
	end)
end

function WorkflowOrchestratorService.new()
	local self = setmetatable({}, WorkflowOrchestratorService)
	self._logger = Logger.new()
	self._dispatcher = Signal.new()

	self._steps = {} :: {WorkflowStep} 

	self._context = {}
	self._currentIndex = 0
	self._paused = false
	self._isRunning = false
	self._rollbacks = {}
	self._onComplete = nil
	self._onError = nil
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

function WorkflowOrchestratorService:InsertStepAt(index: number, step: WorkflowStep)
	assert(type(step) == "table" and type(step.id) == "string" and type(step.action) == "function", "Invalid step")
	assert(index >= 1 and index <= #self._steps + 1, "Index out of bounds")

	for _, existing in ipairs(self._steps) do
		assert(existing.id ~= step.id, "Step ID already exists: " .. step.id)
	end

	table.insert(self._steps, index, step)
	self._logger:Info("Inserted step", { StepId = step.id, Index = index })
end

function WorkflowOrchestratorService:RemoveStepById(stepId: string)
	for i, step in ipairs(self._steps) do
		if step.id == stepId then
			table.remove(self._steps, i)
			self._logger:Info("Removed step", { StepId = stepId })
			return true
		end
	end
	self._logger:Warn("Step not found to remove", { StepId = stepId })
	return false
end

function WorkflowOrchestratorService:GetCurrentStep()
	return self._steps[self._currentIndex]
end

function WorkflowOrchestratorService:IsRunning()
	return self._isRunning
end

function WorkflowOrchestratorService:IsPaused()
	return self._paused
end

function WorkflowOrchestratorService:SkipStep(stepId: string)
	for _, step in ipairs(self._steps) do
		if step.id == stepId then
			step.condition = function() return false end
			self._logger:Info("Step marked to be skipped", { StepId = stepId })
			return true
		end
	end
	self._logger:Warn("Step not found to skip", { StepId = stepId })
	return false
end

function WorkflowOrchestratorService:JumpToStep(stepId: string)
	for i, step in ipairs(self._steps) do
		if step.id == stepId then
			self._currentIndex = i
			self._logger:Info("Jumped to step", { StepId = stepId })
			return true
		end
	end
	self._logger:Warn("Step not found to jump to", { StepId = stepId })
	return false
end

function WorkflowOrchestratorService:GetSteps()
	return DeepCopy(self._steps)
end

function WorkflowOrchestratorService:GetContext()
	return self._context
end

function WorkflowOrchestratorService:OnComplete(callback)
	assert(type(callback) == "function", "Callback must be a function")
	self._onComplete = callback
end

function WorkflowOrchestratorService:OnError(callback)
	assert(type(callback) == "function", "Callback must be a function")
	self._onError = callback
end

function WorkflowOrchestratorService:_runStep(step: WorkflowStep)
	self._logger:Info("Running step", { StepId = step.id })

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
			self._logger:Error("Step failed", { StepId = step.id, Error = err })
			return Promise.reject(err)
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

	local function runNext()
		if self._paused then
			self._logger:Info("Workflow paused at step " .. tostring(self._currentIndex))
			return Promise.reject("Workflow paused")
		end

		if self._currentIndex > #self._steps then
			self._logger:Info("Workflow completed successfully")
			self._isRunning = false
			if self._onComplete then pcall(function() self._onComplete(self._context) end) end
			return Promise.resolve(self._context)
		end

		local step = self._steps[self._currentIndex]

		return self:_runStep(step)
			:andThen(function()
				self._currentIndex = self._currentIndex + 1
				return runNext()
			end)
			:catch(function(err)
				self._logger:Warn("Workflow error, initiating rollback", { Error = err })
				self._isRunning = false
				if self._onError then pcall(function() self._onError(err, self._context) end) end

				return self:_rollback()
				:andThen(function()
					return Promise.reject(err)
				end)
			end)
	end

	return runNext()
end

function WorkflowOrchestratorService:Pause()
	if not self._isRunning then
		self._logger:Warn("Cannot pause; workflow not running")
		return false
	end
	self._paused = true
	self._logger:Info("Workflow paused")
	return true
end

function WorkflowOrchestratorService:Resume()
	if not self._paused then
		self._logger:Warn("Cannot resume; workflow not paused")
		return false
	end
	self._paused = false
	self._logger:Info("Workflow resumed")
	return self:Run(self._context)
end

function WorkflowOrchestratorService:Abort(reason)
	if not self._isRunning then return end
	self._logger:Warn("Workflow aborted", { Reason = reason or "No reason" })
	self._paused = true
	self._isRunning = false
	if self._onError then pcall(function() self._onError(reason or "Aborted", self._context) end) end
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
	self._dispatcher:Destroy()
	self._logger:Info("WorkflowOrchestratorService destroyed")
end

return WorkflowOrchestratorService