--// Parser

local function parseArguments(text)
    local args = {}

    for argument in string.gmatch(text, "%S+") do
        table.insert(args, argument)
    end

    return args
end

local function processCommand(input)
    if not running then
        return false, "runtime_stopped"
    end

    if type(input) ~= "string" then
        return false, "invalid_input"
    end

    if string.sub(input, 1, #PREFIX) ~= PREFIX then
        return false, "missing_prefix"
    end

    startedAt = tick()

    local body = string.sub(input, #PREFIX + 1)
    local args = parseArguments(body)

    if #args == 0 then
        return false, "empty_command"
    end

    local commandName = string.lower(args[1])
    local callback = commands[commandName]

    if not callback then
        local message = 'Command "' .. commandName .. '" not found.'
        replyToHost(message)
        return false, "command_not_found"
    end

    local ok, err = pcall(function()
        callback(unpackArgs(args))
    end)

    if not ok then
        warn("[Account Manager] Command failed:", commandName, err)
        replyToHost('Command "' .. commandName .. '" failed: ' .. tostring(err))
        return false, tostring(err)
    end

    return true, nil
end

