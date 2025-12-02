
A powerful workflow orchestration service for Roblox that supports sequential steps, parallel execution, race conditions, and join operations.

## Usage

```lua
local WorkflowOrchestratorService = require(game.ReplicatedStorage.Package.WorkflowOrchestrator)
local orchestrator = WorkflowOrchestratorService.new()
```

## Features

### Sequential Steps
Add steps that execute one after another:

```lua
orchestrator:AddStep({
    id = "step1",
    action = function(context)
        return Promise.delay(1)
    end
})
```

### Parallel Step Groups
Run multiple step chains simultaneously. All branches must complete successfully:

```lua
orchestrator:AddParallelGroup("parallel_task", {
    -- Branch 1
    {
        { id = "branch1_step1", action = function(ctx) return Promise.delay(2) end },
        { id = "branch1_step2", action = function(ctx) return Promise.delay(1) end }
    },
    -- Branch 2
    {
        { id = "branch2_step1", action = function(ctx) return Promise.delay(1) end },
        { id = "branch2_step2", action = function(ctx) return Promise.delay(2) end }
    }
}, {
    timeout = 10 -- Optional timeout for the entire parallel group
})
```

### Race Groups
Run multiple step chains in parallel, but the first branch to complete wins and cancels the rest:

```lua
orchestrator:AddRaceGroup("race_task", {
    -- Fast branch
    {
        { id = "fast_step", action = function(ctx) return Promise.delay(1) end }
    },
    -- Slow branch
    {
        { id = "slow_step", action = function(ctx) return Promise.delay(5) end }
    }
}, {
    timeout = 10 -- Optional timeout
})
```

### Join Steps
Wait for all parallel branches to finish before proceeding:

```lua
orchestrator:AddJoinStep("join_step", function(context)
    -- Optional action to run after all parallel branches complete
    print("All branches completed!")
    return Promise.resolve(nil)
end, {
    rollback = function(context)
        -- Optional rollback
    end
})
```

## Running the Workflow

```lua
orchestrator:Run({ initialData = "value" })
    :andThen(function(context)
        print("Workflow completed!")
    end)
    :catch(function(err)
        warn("Workflow failed:", err)
    end)
```