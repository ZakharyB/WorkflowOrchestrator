

## Usage

```lua
local WorkflowOrchestratorService = require(game.ReplicatedStorage.Package.WorkflowOrchestrator)
local orchestrator = WorkflowOrchestratorService.new()
```
---

### WorkflowOrchestratorService.new()

When you create a new instance of `WorkflowOrchestratorService` with the `new()`, it will allow the service to initialize

```lua
local orchestrator = WorkflowOrchestratorService.new()
orchestrator.WorkflowStarted:Connect(function()
	print("Workflow execution has started!")
end)
```

---

### WorkflowOrchestratorService:AddStep(step: WorkflowStep)

This registers a new step in the workflow sequence. Each step defines an action or control structure. Yet supporting, Parallel, Race, Loop, Branch, Join logic.
The function validates and adds a `WorkflowStep` to the orchestrator. All the steps **MUST** have a unique `id` and at least one valid execution definition depending on its type ( action, parallelGroups, or branches).

#### Params
- **step** (`WorkflowStep`) the workflow step definition table. **MUST** include:
  - `id`: that's its unique identifier.
  - The rest are optional:
    - `action`: that's what it executes.
    - `parallelGroups`: a Table of grouped steps that are running at the same time.
    - `raceGroups`: a table of grouped steps where only the first one to finish will continue. 
    - `branches`: a list of steps that are conditional. 
    - `loopCondition`: Repeat condition function.  
    - `forEachArray`: iterate over steps
    - `isJoinStep`: Marks a synchronization point.
    
#### Examples
```lua
-- Regular step with a simple action
orchestrator:AddStep({
	id = "Init",
	action = function(ctx)
		print("Initializing context...")
	end
})
```
```lua
-- Parallel groups: run multiple groups of steps at once
orchestrator:AddStep({
	id = "ParallelProcess",
	parallelGroups = {
		{ { id = "TaskA", action = function() print("A") end } },
		{ { id = "TaskB", action = function() print("B") end } },
	}
})
```
```lua
-- Race groups: only the first group to complete continues
orchestrator:AddStep({
	id = "RaceStep",
	raceGroups = {
		{ { id = "Fast", action = function() print("Fast branch") end } },
		{ { id = "Slow", action = function() print("Slow branch") end } },
	}
})
```

```lua
-- Branching logic: conditionally select which steps to run
orchestrator:AddStep({
	id = "ConditionalBranch",
	branches = {
		ifTrue = { { id = "IsTrue", action = function() print("True branch") end } },
		ifFalse = { { id = "IsFalse", action = function() print("False branch") end } },
	}
})
```
```lua
-- Loop condition: repeat step while condition holds
orchestrator:AddStep({
	id = "LoopExample",
	loopCondition = function(ctx)
		ctx.counter = (ctx.counter or 0) + 1
		return ctx.counter < 3
	end,
	action = function() print("Loop iteration") end
})
```
```lua
-- ForEach loop: run step for each item in a list
orchestrator:AddStep({
	id = "ForEachExample",
	forEachArray = { "A", "B", "C" },
	action = function(ctx, item)
		print("Processing:", item)
	end
})
```
```lua
-- Join step: waits for previous parallel/race branches to complete
orchestrator:AddStep({
	id = "JoinPoint",
	isJoinStep = true
})
```

MORE DOCUMENTATION SOON



