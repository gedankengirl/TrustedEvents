local Agent = {}
Agent.__index = Agent

function Agent.New(params)
    local self = setmetatable({}, Agent)
    return self
end


return Agent