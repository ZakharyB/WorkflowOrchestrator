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
	retries: number?,
	parallelGroups: { { WorkflowStep } }?,
	raceGroups: { { WorkflowStep } }?,
	isJoinStep: boolean?,
	branches: { { condition: (Context) -> boolean, nextStepId: string } }?,
	loopCondition: ((Context) -> boolean)?,
	forEachArray: ((Context) -> { any })?,
	forEachSubWorkflow: { WorkflowStep }?,
	maxLoopIterations: number?,
}
export type WorkflowCheckpoint = {
	workflowId: string,
	version: string,
	currentIndex: number,
	context: Context,
	rollbacks: { any },
	timestamp: number,
}
export type ScheduledWorkflow = {
	id: string,
	workflowId: string,
	scheduleTime: number?,
	interval: number?,
	enabled: boolean,
	lastRun: number?,
}

local function DeepCopy(orig: any, visited: { [any]: any }?): any
	local orig_type = type(orig)
	local copy

	if orig_type == "table" then
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
	Rejected = "Rejected",
}

function Promise.new(executor)
	local self = setmetatable({
		_status = PROMISE_Status.Pending,
		_value = nil,
		_callbacks = {},
	}, Promise)

	local function resolve(val: any?)
		if self._status ~= PROMISE_Status.Pending then
			return
		end
		self._status = PROMISE_Status.Resolved
		self._value = val
		for _, cb in ipairs(self._callbacks) do
			if cb.onFulfilled then
				task.spawn(cb.onFulfilled, val)
			end
		end
	end

	local function reject(err)
		if self._status ~= PROMISE_Status.Pending then
			return
		end
		self._status = PROMISE_Status.Rejected
		self._value = err
		for _, cb in ipairs(self._callbacks) do
			if cb.onRejected then
				task.spawn(cb.onRejected, err)
			end
		end
	end

	task.spawn(function()
		local success, err = pcall(function()
			executor(resolve, reject)
		end)
		if not success then
			reject(err)
		end
	end)

	return self
end

function Promise.resolve(val)
	return Promise.new(function(resolve)
		resolve(val)
	end)
end

function Promise.reject(val)
	return Promise.new(function(_, reject)
		reject(val)
	end)
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

function Promise.all(promises)
	return Promise.new(function(resolve, reject)
		if #promises == 0 then
			resolve({})
			return
		end

		local results = {}
		local completed = 0
		local hasError = false

		for i, p in ipairs(promises) do
			local promiseObj = p :: any
			promiseObj:andThen(function(val)
				if not hasError then
					results[i] = val
					completed = completed + 1
					if completed == #promises then
						resolve(results)
					end
				end
			end, function(err)
				if not hasError then
					hasError = true
					reject(err)
				end
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

	self._steps = {} :: { WorkflowStep }
	self._context = {}
	self._currentIndex = 0
	self._paused = false
	self._isRunning = false
	self._rollbacks = {}
	self._activeBranches = {}
	self._joinStepWaiting = false
	self._workflowId = ""
	self._version = "1.0"
	self._workflowTimeout = nil
	self._workflowTimeoutPromise = nil
	self._checkpointStorage = {}
	self._stepIdToIndex = {}
	self._versions = {}
	self._loopIterations = {}

	self._mainResolve = nil
	self._mainReject = nil

	return self
end

function WorkflowOrchestratorService:AddStep(step: WorkflowStep)
	assert(type(step) == "table", "Step must be a table")
	assert(type(step.id) == "string", "Step must have string id")

	local hasAction = type(step.action) == "function"
	local hasParallelGroups = step.parallelGroups ~= nil
	local hasRaceGroups = step.raceGroups ~= nil
	local isJoin = step.isJoinStep == true
	local hasBranches = step.branches ~= nil
	local hasLoop = step.loopCondition ~= nil
	local hasForEach = step.forEachArray ~= nil

	assert(
		hasAction or hasParallelGroups or hasRaceGroups or isJoin or hasBranches or hasLoop or hasForEach,
		"Step must have action function, parallelGroups, raceGroups, branches, loopCondition, forEachArray, or be a join step"
	)

	if hasParallelGroups then
		assert(type(step.parallelGroups) == "table", "parallelGroups must be a table")
		for i, group in ipairs(step.parallelGroups) do
			assert(type(group) == "table", "Parallel group " .. tostring(i) .. " must be a table")
			for j, subStep in ipairs(group) do
				assert(
					type(subStep) == "table" and type(subStep.id) == "string",
					"Parallel group " .. tostring(i) .. " step " .. tostring(j) .. " must be a valid WorkflowStep"
				)
			end
		end
	end

	if hasRaceGroups then
		assert(type(step.raceGroups) == "table", "raceGroups must be a table")
		for i, group in ipairs(step.raceGroups) do
			assert(type(group) == "table", "Race group " .. tostring(i) .. " must be a table")
			for j, subStep in ipairs(group) do
				assert(
					type(subStep) == "table" and type(subStep.id) == "string",
					"Race group " .. tostring(i) .. " step " .. tostring(j) .. " must be a valid WorkflowStep"
				)
			end
		end
	end

	for _, existing in ipairs(self._steps) do
		assert(existing.id ~= step.id, "Step ID already exists: " .. step.id)
	end

	table.insert(self._steps, step)
	self:_rebuildStepIndex()
	self._logger:Info(
		"Added workflow step",
		{
			StepId = step.id,
			Type = hasParallelGroups and "ParallelGroup"
				or hasRaceGroups and "RaceGroup"
				or isJoin and "JoinStep"
				or hasBranches and "Branch"
				or hasLoop and "Loop"
				or hasForEach and "ForEach"
				or "Regular",
		}
	)
end

function WorkflowOrchestratorService:_rebuildStepIndex()
	self._stepIdToIndex = {}
	for i, step in ipairs(self._steps) do
		self._stepIdToIndex[step.id] = i
	end
end

function WorkflowOrchestratorService:AddParallelGroup(
	id: string,
	stepChains: { { WorkflowStep } },
	options: { condition: ((Context) -> boolean)?, timeout: number? }?
)
	options = options or {}
	local step: WorkflowStep = {
		id = id,
		action = function()
			return Promise.resolve(nil)
		end,
		parallelGroups = stepChains,
		condition = options.condition,
		timeout = options.timeout,
	}
	self:AddStep(step)
	return self
end

function WorkflowOrchestratorService:AddRaceGroup(
	id: string,
	stepChains: { { WorkflowStep } },
	options: { condition: ((Context) -> boolean)?, timeout: number? }?
)
	options = options or {}
	local step: WorkflowStep = {
		id = id,
		action = function()
			return Promise.resolve(nil)
		end,
		raceGroups = stepChains,
		condition = options.condition,
		timeout = options.timeout,
	}
	self:AddStep(step)
	return self
end

function WorkflowOrchestratorService:AddJoinStep(
	id: string,
	action: ((Context) -> any)?,
	options: { condition: ((Context) -> boolean)?, rollback: ((Context) -> ())? }?
)
	options = options or {}
	local step: WorkflowStep = {
		id = id,
		action = action or function()
			return Promise.resolve(nil)
		end,
		isJoinStep = true,
		condition = options.condition,
		rollback = options.rollback,
	}
	self:AddStep(step)
	return self
end

function WorkflowOrchestratorService:GetSteps()
	return DeepCopy(self._steps)
end

function WorkflowOrchestratorService:SetVersion(version: string)
	if not self._versions[self._version] then
		self._versions[self._version] = DeepCopy(self._steps)
	end
	self._version = version
	if self._versions[version] then
		self._steps = DeepCopy(self._versions[version])
		self:_rebuildStepIndex()
	else
		self._versions[version] = DeepCopy(self._steps)
	end
end

function WorkflowOrchestratorService:GetVersion()
	return self._version
end

function WorkflowOrchestratorService:InjectStep(step: WorkflowStep, afterStepId: string?)
	if afterStepId then
		local index = self._stepIdToIndex[afterStepId]
		if index then
			table.insert(self._steps, index + 1, step)
			self:_rebuildStepIndex()
			self._logger:Info("Injected step after", { StepId = step.id, AfterStepId = afterStepId })
		else
			error("Step not found: " .. afterStepId)
		end
	else
		table.insert(self._steps, step)
		self:_rebuildStepIndex()
		self._logger:Info("Injected step at end", { StepId = step.id })
	end
end

function WorkflowOrchestratorService:RemoveStep(stepId: string)
	local index = self._stepIdToIndex[stepId]
	if not index then
		error("Step not found: " .. stepId)
	end

	table.remove(self._steps, index)

	if self._currentIndex >= index and self._isRunning then
		self._currentIndex = self._currentIndex - 1
	end

	self:_rebuildStepIndex()
	self._logger:Info("Removed step", { StepId = stepId })
end

function WorkflowOrchestratorService:SaveCheckpoint()
	if not self._workflowId or self._workflowId == "" then
		return
	end

	local checkpoint: WorkflowCheckpoint = {
		workflowId = self._workflowId,
		version = self._version,
		currentIndex = self._currentIndex,
		context = DeepCopy(self._context),
		rollbacks = DeepCopy(self._rollbacks),
		timestamp = os.time(),
	}

	self._checkpointStorage[self._workflowId] = checkpoint
	self._logger:Info("Checkpoint saved", { WorkflowId = self._workflowId, Index = self._currentIndex })
end

function WorkflowOrchestratorService:LoadCheckpoint(workflowId: string): boolean
	local checkpoint = self._checkpointStorage[workflowId]
	if not checkpoint then
		return false
	end

	if checkpoint.version ~= self._version then
		if self._versions[checkpoint.version] then
			self._steps = DeepCopy(self._versions[checkpoint.version])
			self._version = checkpoint.version
			self:_rebuildStepIndex()
		else
			self._logger:Warn("Version not found, using current", { Version = checkpoint.version })
		end
	end

	self._workflowId = checkpoint.workflowId
	self._currentIndex = checkpoint.currentIndex
	self._context = DeepCopy(checkpoint.context)
	self._rollbacks = DeepCopy(checkpoint.rollbacks)

	self:_rebuildStepIndex()

	self._logger:Info("Checkpoint loaded", { WorkflowId = workflowId, Index = self._currentIndex })
	return true
end

function WorkflowOrchestratorService:SetWorkflowTimeout(seconds: number)
	self._workflowTimeout = seconds
end

function WorkflowOrchestratorService:SetCheckpointStorage(storage: { [string]: WorkflowCheckpoint })
	self._checkpointStorage = storage
end

function WorkflowOrchestratorService:_runStepChain(stepChain: { WorkflowStep }, chainId: string, startIndex: number)
	startIndex = startIndex or 1

	if startIndex > #stepChain then
		return Promise.resolve(nil)
	end

	local step = stepChain[startIndex]
	return self:_runStep(step):andThen(function()
		return self:_runStepChain(stepChain, chainId, startIndex + 1)
	end)
end

function WorkflowOrchestratorService:_runStep(step: WorkflowStep)
	self._logger:Info("Running step", { StepId = step.id })
	self.StepStarted:Fire(step.id, self._context)

	if step.condition and not step.condition(self._context) then
		self._logger:Info("Skipping step due to condition", { StepId = step.id })
		return Promise.resolve(nil)
	end

	if step.parallelGroups then
		self._logger:Info("Executing parallel group", { StepId = step.id, BranchCount = #step.parallelGroups })
		local branchPromises = {}
		local branchRollbacks = {}

		for i, stepChain in ipairs(step.parallelGroups) do
			local branchId = step.id .. "_branch_" .. tostring(i)
			local branchRollbackList = {}

			local rollbackStartIndex = #self._rollbacks + 1

			local branchPromise = self:_runStepChain(stepChain, branchId, 1):andThen(function(result)
				for j = rollbackStartIndex, #self._rollbacks do
					table.insert(branchRollbackList, self._rollbacks[j])
				end
				return result
			end)

			table.insert(branchPromises, branchPromise)
			table.insert(branchRollbacks, branchRollbackList)
		end

		local allPromise = Promise.all(branchPromises)

		if step.timeout then
			allPromise = Promise.race({
				allPromise,
				Promise.delay(step.timeout):andThen(function()
					return Promise.reject(
						"Parallel group '" .. step.id .. "' timed out after " .. tostring(step.timeout) .. " seconds"
					)
				end),
			})
		end

		return allPromise
			:andThen(function(results)
				self._logger:Info("Parallel group completed", { StepId = step.id })
				self.StepCompleted:Fire(step.id, results, self._context)
				return results
			end)
			:catch(function(err)
				self.StepFailed:Fire(step.id, err)
				self._logger:Error("Parallel group failed", { StepId = step.id, Error = err })
				return Promise.reject(err)
			end)
	end

	if step.raceGroups then
		self._logger:Info("Executing race group", { StepId = step.id, BranchCount = #step.raceGroups })
		local branchPromises = {}
		local cancelledBranches = {}

		for i, stepChain in ipairs(step.raceGroups) do
			local branchId = step.id .. "_race_branch_" .. tostring(i)
			local branchCancelled = false
			cancelledBranches[i] = false

			local branchPromise = Promise.new(function(resolve, reject)
				self:_runStepChain(stepChain, branchId, 1)
					:andThen(function(result)
						if not cancelledBranches[i] then
							for j = 1, #step.raceGroups do
								if j ~= i then
									cancelledBranches[j] = true
								end
							end
							resolve({ branchIndex = i, result = result })
						end
					end)
					:catch(function(err)
						if not cancelledBranches[i] then
							reject(err)
						end
					end)
			end)

			table.insert(branchPromises, branchPromise)
		end

		local racePromise = Promise.race(branchPromises)

		if step.timeout then
			racePromise = Promise.race({
				racePromise,
				Promise.delay(step.timeout):andThen(function()
					return Promise.reject(
						"Race group '" .. step.id .. "' timed out after " .. tostring(step.timeout) .. " seconds"
					)
				end),
			})
		end

		return racePromise
			:andThen(function(winner)
				self._logger:Info("Race group completed", { StepId = step.id, WinnerBranch = winner.branchIndex })
				self.StepCompleted:Fire(step.id, winner, self._context)
				return winner
			end)
			:catch(function(err)
				self.StepFailed:Fire(step.id, err)
				self._logger:Error("Race group failed", { StepId = step.id, Error = err })
				return Promise.reject(err)
			end)
	end

	if step.branches then
		self._logger:Info("Executing branch step", { StepId = step.id })

		local promise = Promise.resolve(nil)
		if step.action then
			local actionResult = step.action(self._context)
			if actionResult and type(actionResult) == "table" and actionResult.andThen then
				promise = actionResult :: any
			else
				promise = Promise.resolve(actionResult)
			end
		end

		return promise:andThen(function(result)
			local nextStepId = nil
			for _, branch in ipairs(step.branches) do
				if branch.condition(self._context) then
					nextStepId = branch.nextStepId
					break
				end
			end

			if nextStepId then
				local nextIndex = self._stepIdToIndex[nextStepId]
				if nextIndex then
					self._currentIndex = nextIndex - 1
					self._logger:Info("Branching to step", { FromStepId = step.id, ToStepId = nextStepId })
				else
					self._logger:Warn("Branch target not found", { StepId = step.id, TargetStepId = nextStepId })
					return Promise.reject("Branch target not found: " .. nextStepId)
				end
			else
				self._currentIndex = self._currentIndex + 1
			end

			self.StepCompleted:Fire(step.id, result, self._context)
			return result
		end)
	end

	if step.loopCondition then
		self._logger:Info("Executing loop step", { StepId = step.id })

		local loopKey = step.id
		if not self._loopIterations[loopKey] then
			self._loopIterations[loopKey] = 0
		end

		local maxIterations = step.maxLoopIterations or 1000

		local function runLoopIteration()
			if self._loopIterations[loopKey] >= maxIterations then
				self._logger:Warn(
					"Loop max iterations reached",
					{ StepId = step.id, Iterations = self._loopIterations[loopKey] }
				)
				return Promise.resolve(nil)
			end

			if step.loopCondition(self._context) then
				self._loopIterations[loopKey] = self._loopIterations[loopKey] + 1

				local promise = Promise.resolve(nil)
				if step.action then
					local actionResult = step.action(self._context)
					if actionResult and type(actionResult) == "table" and actionResult.andThen then
						promise = actionResult :: any
					else
						promise = Promise.resolve(actionResult)
					end
				end

				return promise:andThen(function()
					return runLoopIteration()
				end)
			else
				self._loopIterations[loopKey] = nil
				return Promise.resolve(nil)
			end
		end

		return runLoopIteration():andThen(function(result)
			self.StepCompleted:Fire(step.id, result, self._context)
			return result
		end)
	end

	if step.forEachArray then
		self._logger:Info("Executing forEach step", { StepId = step.id })

		local array = step.forEachArray(self._context)
		if not array or type(array) ~= "table" then
			return Promise.reject("forEachArray must return a table")
		end

		if not step.forEachSubWorkflow or #step.forEachSubWorkflow == 0 then
			return Promise.reject("forEachSubWorkflow must be provided")
		end

		local itemPromises = {}
		for i, item in ipairs(array) do
			local originalContext = self._context
			local itemContext = DeepCopy(self._context)
			itemContext._forEachItem = item
			itemContext._forEachIndex = i
			self._context = itemContext

			local itemPromise = self:_runStepChain(step.forEachSubWorkflow, step.id .. "_forEach_" .. tostring(i), 1)
				:andThen(function(result)
					self._context = originalContext
					return result
				end)
				:catch(function(err)
					self._context = originalContext
					return Promise.reject(err)
				end)

			table.insert(itemPromises, itemPromise)
		end

		return Promise.all(itemPromises):andThen(function(results)
			self.StepCompleted:Fire(step.id, results, self._context)
			return results
		end)
	end

	if step.isJoinStep then
		self._logger:Info("Executing join step", { StepId = step.id })

		local promise = Promise.resolve(nil)

		if step.action then
			local actionResult = step.action(self._context)
			if actionResult and type(actionResult) == "table" and actionResult.andThen then
				promise = actionResult :: any
			else
				promise = Promise.resolve(actionResult)
			end
		end

		return promise
			:andThen(function(result)
				self._logger:Info("Join step completed", { StepId = step.id })
				self.StepCompleted:Fire(step.id, result, self._context)

				if step.rollback then
					table.insert(self._rollbacks, function()
						self._logger:Info("Running rollback for join step", { StepId = step.id })
						local success, err = pcall(function()
							if step.rollback then
								step.rollback(self._context)
							end
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
				self._logger:Error("Join step failed", { StepId = step.id, Error = err })
				return Promise.reject(err)
			end)
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
					return Promise.reject(
						"Step '" .. step.id .. "' timed out after " .. tostring(step.timeout) .. " seconds"
					)
				end),
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
						if step.rollback then
							step.rollback(self._context)
						end
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

		if self._workflowId and self._workflowId ~= "" then
			self._checkpointStorage[self._workflowId] = nil
		end

		if self._workflowTimeoutPromise then
			self._workflowTimeoutPromise = nil
		end

		self.WorkflowCompleted:Fire(self._context)

		if self._mainResolve then
			self._mainResolve(self._context)
		end
		return
	end

	local step = self._steps[self._currentIndex]

	if self._workflowId and self._workflowId ~= "" then
		self:SaveCheckpoint()
	end

	self:_runStep(step)
		:andThen(function()
			if not self._isRunning then
				return
			end
			self._currentIndex = self._currentIndex + 1
			self:_processQueue()
		end)
		:catch(function(err)
			self._logger:Warn("Workflow error, initiating rollback", { Error = err })
			self._isRunning = false

			if self._workflowTimeoutPromise then
				self._workflowTimeoutPromise = nil
			end

			self.WorkflowFailed:Fire(err, self._context)

			self:_rollback():andThen(function()
				if self._mainReject then
					self._mainReject(err)
				end
			end)
		end)
end

function WorkflowOrchestratorService:Run(context, workflowId: string?)
	assert(not self._isRunning, "Workflow already running")

	self._isRunning = true
	self._paused = false
	self._context = context or {}
	self._currentIndex = 1
	self._rollbacks = {}
	self._workflowId = workflowId or ""
	self._loopIterations = {}

	if self._workflowTimeout then
		self._workflowTimeoutPromise = Promise.delay(self._workflowTimeout):andThen(function()
			if self._isRunning then
				self._logger:Warn("Workflow timeout", { Timeout = self._workflowTimeout })
				self:Abort("Workflow timed out after " .. tostring(self._workflowTimeout) .. " seconds")
			end
		end)
	end

	self._logger:Info("Workflow started", { WorkflowId = self._workflowId })
	self.WorkflowStarted:Fire(self._context)

	return Promise.new(function(resolve, reject)
		self._mainResolve = resolve
		self._mainReject = reject

		self:_processQueue()
	end)
end

function WorkflowOrchestratorService:ResumeFromCheckpoint(workflowId: string, context: Context?)
	assert(not self._isRunning, "Workflow already running")

	if not self:LoadCheckpoint(workflowId) then
		error("Checkpoint not found: " .. workflowId)
	end

	if context then
		for k, v in pairs(context) do
			self._context[k] = v
		end
	end

	self._isRunning = true
	self._paused = false
	self._loopIterations = {}

	if self._workflowTimeout then
		self._workflowTimeoutPromise = Promise.delay(self._workflowTimeout):andThen(function()
			if self._isRunning then
				self._logger:Warn("Workflow timeout", { Timeout = self._workflowTimeout })
				self:Abort("Workflow timed out after " .. tostring(self._workflowTimeout) .. " seconds")
			end
		end)
	end

	self._logger:Info("Workflow resumed from checkpoint", { WorkflowId = workflowId, Index = self._currentIndex })
	self.WorkflowResumed:Fire(self._currentIndex)

	return Promise.new(function(resolve, reject)
		self._mainResolve = resolve
		self._mainReject = reject

		self:_processQueue()
	end)
end

function WorkflowOrchestratorService:Pause()
	if not self._isRunning then
		return false
	end
	if self._paused then
		return false
	end

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
	if not self._isRunning then
		return
	end

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
	self._activeBranches = {}
	self._joinStepWaiting = false
	self._workflowId = ""
	self._workflowTimeout = nil
	self._workflowTimeoutPromise = nil
	self._loopIterations = {}
	self._stepIdToIndex = {}
	self:_rebuildStepIndex()
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

local WorkflowManager = {}
WorkflowManager.__index = WorkflowManager

function WorkflowManager.new()
	local self = setmetatable({}, WorkflowManager)
	self._logger = Logger.new()
	self._activeWorkflows = {}
	self._queue = {}
	self._concurrencyLimit = math.huge
	self._scheduledWorkflows = {}
	self._schedulerThread = nil
	self._workflowInstances = {}

	return self
end

function WorkflowManager:SetConcurrencyLimit(limit: number)
	self._concurrencyLimit = limit
	self._logger:Info("Concurrency limit set", { Limit = limit })
end

function WorkflowManager:CreateWorkflow(id: string): WorkflowOrchestratorService
	local workflow = WorkflowOrchestratorService.new()
	workflow._workflowId = id
	self._workflowInstances[id] = workflow
	return workflow
end

function WorkflowManager:GetWorkflow(id: string): WorkflowOrchestratorService?
	return self._workflowInstances[id]
end

function WorkflowManager:QueueWorkflow(workflowId: string, context: Context?)
	table.insert(self._queue, { workflowId = workflowId, context = context })
	self._logger:Info("Workflow queued", { WorkflowId = workflowId, QueuePosition = #self._queue })
	self:_processQueue()
end

function WorkflowManager:_processQueue()
	while #self._queue > 0 and #self._activeWorkflows < self._concurrencyLimit do
		local queued = table.remove(self._queue, 1)
		local workflow = self._workflowInstances[queued.workflowId]

		if workflow then
			table.insert(self._activeWorkflows, queued.workflowId)

			workflow
				:Run(queued.context, queued.workflowId)
				:andThen(function()
					for i, id in ipairs(self._activeWorkflows) do
						if id == queued.workflowId then
							table.remove(self._activeWorkflows, i)
							break
						end
					end
					self._logger:Info("Workflow completed", { WorkflowId = queued.workflowId })
					self:_processQueue()
				end)
				:catch(function(err)
					for i, id in ipairs(self._activeWorkflows) do
						if id == queued.workflowId then
							table.remove(self._activeWorkflows, i)
							break
						end
					end
					self._logger:Error("Workflow failed", { WorkflowId = queued.workflowId, Error = err })
					self:_processQueue()
				end)
		else
			self._logger:Warn("Workflow not found in queue", { WorkflowId = queued.workflowId })
		end
	end
end

function WorkflowManager:ScheduleWorkflow(id: string, workflowId: string, scheduleTime: number?, interval: number?)
	local scheduled: ScheduledWorkflow = {
		id = id,
		workflowId = workflowId,
		scheduleTime = scheduleTime,
		interval = interval,
		enabled = true,
		lastRun = nil,
	}

	self._scheduledWorkflows[id] = scheduled
	self._logger:Info("Workflow scheduled", { ScheduleId = id, WorkflowId = workflowId })

	if not self._schedulerThread then
		self:_startScheduler()
	end
end

function WorkflowManager:_startScheduler()
	if self._schedulerThread then
		return
	end

	self._schedulerThread = task.spawn(function()
		while true do
			task.wait(1)

			local currentTime = os.time()

			for scheduleId, scheduled in pairs(self._scheduledWorkflows) do
				if not scheduled.enabled then
					continue
				end

				local shouldRun = false

				if scheduled.scheduleTime then
					if
						currentTime >= scheduled.scheduleTime
						and (not scheduled.lastRun or scheduled.lastRun < scheduled.scheduleTime)
					then
						shouldRun = true
					end
				end

				if scheduled.interval then
					if not scheduled.lastRun or (currentTime - scheduled.lastRun) >= scheduled.interval then
						shouldRun = true
					end
				end

				if shouldRun then
					scheduled.lastRun = currentTime
					self:QueueWorkflow(scheduled.workflowId, {})
				end
			end
		end
	end)
end

function WorkflowManager:EnableScheduledWorkflow(scheduleId: string)
	local scheduled = self._scheduledWorkflows[scheduleId]
	if scheduled then
		scheduled.enabled = true
		self._logger:Info("Scheduled workflow enabled", { ScheduleId = scheduleId })
	end
end

function WorkflowManager:DisableScheduledWorkflow(scheduleId: string)
	local scheduled = self._scheduledWorkflows[scheduleId]
	if scheduled then
		scheduled.enabled = false
		self._logger:Info("Scheduled workflow disabled", { ScheduleId = scheduleId })
	end
end

function WorkflowManager:RemoveScheduledWorkflow(scheduleId: string)
	self._scheduledWorkflows[scheduleId] = nil
	self._logger:Info("Scheduled workflow removed", { ScheduleId = scheduleId })
end

function WorkflowManager:GetActiveWorkflows(): { string }
	return DeepCopy(self._activeWorkflows)
end

function WorkflowManager:GetQueueLength(): number
	return #self._queue
end

WorkflowOrchestratorService.Manager = WorkflowManager

return WorkflowOrchestratorService
