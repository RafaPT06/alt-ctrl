--// Parser

local function parseArguments(text)
    local args = {}

    for argument in string.gmatch(text, "%S+") do
        table.insert(args, argument)
    end

    return args
end

local function processCommand(input)
    if not running or type(input) ~= "string" then
        return
    end

    if string.sub(input, 1, #PREFIX) ~= PREFIX then
        return
    end

    startedAt = tick()

    local body = string.sub(input, #PREFIX + 1)
    local args = parseArguments(body)

    if #args == 0 then
        return
    end

    local commandName = string.lower(args[1])
    local callback = commands[commandName]

    if not callback then
        replyToHost('Command "' .. commandName .. '" not found.')
        return
    end

    local ok, err = pcall(function()
        callback(unpackArgs(args))
    end)

    if not ok then
        warn(
            "[Account Manager] Command failed:",
            commandName,
            err
        )
        replyToHost('Command "' .. commandName .. '" failed: ' .. tostring(err))
    end
end

