--[[
    Account Manager v3
    Modified by Rafa

    Clean rewrite of the original Account Manager.

    SETUP:
      MAIN / PC  = controller only (no executor required)
      ALT / PHONE = executes this script and performs the commands

    The script only accepts commands from HOST_USER_ID.
    LocalPlayer is always the ALT running this script.
]]

--// Configuration

local PREFIX = ","
local VERSION = "3.1"

local HOST_USER_ID = 3104567111
local ACCOUNTS = {
    9039839654,
}

--// Services

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TeleportService = game:GetService("TeleportService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")

--// Runtime

local startedAt = tick()
-- LocalPlayer = the ALT on the phone executing this script.
-- Host        = the MAIN on the PC controlling the alt through chat.
local LocalPlayer = Players.LocalPlayer
local Host = Players:GetPlayerByUserId(HOST_USER_ID)

local function isManagedLocalAccount()
    for _, userId in ipairs(ACCOUNTS) do
        if LocalPlayer.UserId == userId then
            return true
        end
    end
    return false
end

local running = true
local commands = {}
local commandInfo = {}
local botStates = {}

--// Utilities

local function getCharacter(player)
    if not player then
        return nil, nil, nil
    end

    local character = player.Character
    if not character then
        return nil, nil, nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")

    return character, humanoid, root
end

local function getRoot(player)
    local _, _, root = getCharacter(player)
    return root
end

local function getHumanoid(player)
    local _, humanoid = getCharacter(player)
    return humanoid
end

local function findPlayer(query)
    if query == nil or query == "" or string.lower(query) == "me" then
        return Host
    end

    query = string.lower(query)

    -- Exact username/display-name match first.
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.Name) == query
            or string.lower(player.DisplayName) == query then
            return player
        end
    end

    -- Then partial username/display-name match.
    for _, player in ipairs(Players:GetPlayers()) do
        if string.find(string.lower(player.Name), query, 1, true)
            or string.find(string.lower(player.DisplayName), query, 1, true) then
            return player
        end
    end

    return nil
end

local function getManagedBots()
    local bots = {}

    -- A LocalScript/executor can directly control only the client it is running on.
    -- Therefore this phone instance manages LocalPlayer when its UserId is listed
    -- in ACCOUNTS. If you run the same script on another alt, that alt manages itself.
    for accountIndex, userId in ipairs(ACCOUNTS) do
        if LocalPlayer.UserId == userId then
            table.insert(bots, {
                player = LocalPlayer,
                accountIndex = accountIndex,
            })
            break
        end
    end

    return bots
end

local function getBotState(player)
    local userId = player.UserId

    if not botStates[userId] then
        botStates[userId] = {
            mode = nil,
            token = 0,
            target = nil,
            defaultWalkSpeed = nil,
        }
    end

    return botStates[userId]
end

local function stopBotMovement(player)
    local state = getBotState(player)

    state.token = state.token + 1
    state.mode = nil
    state.target = nil

    local humanoid = getHumanoid(player)
    if humanoid then
        humanoid:Move(Vector3.zero)
    end
end

local function stopAllMovement()
    for _, entry in ipairs(getManagedBots()) do
        stopBotMovement(entry.player)
    end
end

local function beginBotMode(player, mode, target)
    local state = getBotState(player)

    -- Invalidates any old loop belonging to this bot.
    state.token = state.token + 1
    state.mode = mode
    state.target = target

    return state.token
end

local function isModeActive(player, mode, token)
    local state = getBotState(player)

    return running
        and state.mode == mode
        and state.token == token
end

--// Chat

local function usingTextChatService()
    return TextChatService.ChatVersion == Enum.ChatVersion.TextChatService
end

local function sendMessage(value)
    local text = tostring(value)

    if usingTextChatService() then
        local channels = TextChatService:FindFirstChild("TextChannels")
        local general = channels and channels:FindFirstChild("RBXGeneral")

        if general then
            local ok, err = pcall(function()
                general:SendAsync(text)
            end)

            if not ok then
                warn("[Account Manager] Failed to send chat message:", err)
            end
        end
    else
        local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        local sayRequest = chatEvents and chatEvents:FindFirstChild("SayMessageRequest")

        if sayRequest then
            sayRequest:FireServer(text, "All")
        end
    end
end

local function sendEmote(emote)
    -- The ALT is the LocalPlayer on this phone, so the emote command is sent
    -- from this client. The MAIN does not need to execute anything.
    local command = "/e " .. tostring(emote)

    if usingTextChatService() then
        local channels = TextChatService:FindFirstChild("TextChannels")
        local general = channels and channels:FindFirstChild("RBXGeneral")

        if general then
            local ok = pcall(function()
                general:SendAsync(command)
            end)

            if ok then
                return
            end
        end
    end

    -- Legacy/fallback behavior.
    pcall(function()
        Players:Chat(command)
    end)
end

--// Commands

local function addCommand(names, description, callback)
    assert(type(names) == "table", "Command names must be a table")
    assert(type(callback) == "function", "Command callback must be a function")

    local primary = names[1]

    commandInfo[primary] = {
        aliases = names,
        description = description or "",
    }

    for _, name in ipairs(names) do
        if type(name) ~= "string" then
            warn("[Account Manager] Invalid alias type:", typeof(name))
        else
            name = string.lower(name)

            if commands[name] then
                warn("[Account Manager] Duplicate command alias:", name)
            else
                commands[name] = callback
            end
        end
    end
end

addCommand({ "ex", "example", "debug" }, "Show command response time.", function()
    sendMessage(
        "Identified in "
            .. string.format("%.2f", tick() - startedAt)
            .. " seconds."
    )
end)

addCommand({ "rejoin", "rj", "rej", "reconnect", "r" }, "Rejoin the current server.", function()
    TeleportService:TeleportToPlaceInstance(
        game.PlaceId,
        game.JobId,
        LocalPlayer
    )
end)

addCommand({ "bring" }, "Bring managed accounts beside the host.", function()
    local hostRoot = getRoot(Host)

    if not hostRoot then
        sendMessage("Host character is not ready.")
        return
    end

    local bots = getManagedBots()

    for i, entry in ipairs(bots) do
        local bot = entry.player
        local root = getRoot(bot)

        if root then
            stopBotMovement(bot)

            local x = (i - (#bots / 2) - 0.5) * 4
            local destination = hostRoot.CFrame * CFrame.new(x, 0, 3)

            TweenService:Create(
                root,
                TweenInfo.new(0.25, Enum.EasingStyle.Sine),
                { CFrame = destination }
            ):Play()
        end
    end
end)

addCommand({ "line" }, "Line accounts left/right/front/back of the host.", function(_, ...)
    local direction = string.lower(table.concat({ ... }, " "))
    local hostRoot = getRoot(Host)

    if not hostRoot then
        sendMessage("Host character is not ready.")
        return
    end

    if direction == "" then
        sendMessage("Usage: " .. PREFIX .. "line <left/right/front/back>")
        return
    end

    local bots = getManagedBots()

    for i, entry in ipairs(bots) do
        local bot = entry.player
        local root = getRoot(bot)

        if root then
            stopBotMovement(bot)

            local offset

            if direction == "left" or direction == "l" then
                offset = CFrame.new(-i * 4, 0, 0)
            elseif direction == "right" or direction == "r" then
                offset = CFrame.new(i * 4, 0, 0)
            elseif direction == "back" or direction == "b" then
                offset = CFrame.new(0, 0, i * 4)
            elseif direction == "front" or direction == "f" then
                offset = CFrame.new(0, 0, -i * 4)
            else
                sendMessage("Unknown line direction: " .. direction)
                return
            end

            TweenService:Create(
                root,
                TweenInfo.new(0.25, Enum.EasingStyle.Sine),
                { CFrame = hostRoot.CFrame * offset }
            ):Play()
        end
    end
end)

addCommand({ "orbit", "circle" }, "Orbit a player. Usage: ,orbit player [speed] [radius]", function(_, targetName, speedArg, radiusArg)
    local target = findPlayer(targetName)
    local speed = tonumber(speedArg) or 2
    local radius = tonumber(radiusArg) or 5

    if not target then
        sendMessage("Target not found.")
        return
    end

    if radius <= 0 then
        sendMessage("Radius must be greater than 0.")
        return
    end

    local bots = getManagedBots()

    for i, entry in ipairs(bots) do
        local bot = entry.player
        local token = beginBotMode(bot, "orbit", target)

        task.spawn(function()
            -- Spread multiple accounts around the circle.
            local angle = ((i - 1) / math.max(#bots, 1)) * math.pi * 2

            while isModeActive(bot, "orbit", token) do
                local targetRoot = getRoot(target)
                local botRoot = getRoot(bot)

                if targetRoot and botRoot then
                    local x = math.cos(angle) * radius
                    local z = math.sin(angle) * radius
                    local destination = targetRoot.Position + Vector3.new(x, 0, z)

                    botRoot.CFrame = CFrame.lookAt(
                        destination,
                        targetRoot.Position
                    )

                    angle = angle + math.rad(speed)
                end

                task.wait(0.05)
            end
        end)
    end
end)

addCommand({ "unorbit", "stoporbit" }, "Stop orbiting.", function()
    for _, entry in ipairs(getManagedBots()) do
        local state = getBotState(entry.player)

        if state.mode == "orbit" then
            stopBotMovement(entry.player)
        end
    end
end)

addCommand({ "promo", "promote", "share", "brag", "advertise", "ad" }, "Show Account Manager version.", function()
    if #getManagedBots() > 0 then
        sendMessage("Account Manager version " .. VERSION .. " modified by Rafa")
    end
end)

addCommand({ "index", "ingame", "online" }, "Show number of managed accounts online.", function()
    sendMessage("Managing " .. #getManagedBots() .. " accounts.")
end)

addCommand({ "meatballify", "meatball", "gwibard" }, "Run the existing meatballify script.", function()
    local ok, err = pcall(function()
        loadstring(
            game:HttpGetAsync(
                "https://new-cloudbin.koyeb.app/raw/eTNvTLkf.txt",
                true
            )
        )()
    end)

    if not ok then
        warn("[Account Manager] meatballify failed:", err)
        sendMessage("Meatballify failed to load.")
    end
end)

addCommand({ "end", "stop", "quit", "exit", "close" }, "Disable Account Manager commands.", function()
    stopAllMovement()
    running = false
    sendMessage("Account Manager successfully closed.")
end)

addCommand({ "dance", "groove" }, "Dance. Usage: ,dance [1/2/3]", function(_, dance)
    dance = tostring(dance or "1")

    if dance == "1" then
        sendEmote("dance")
    else
        sendEmote("dance" .. dance)
    end
end)

addCommand({ "wave", "hello" }, "Wave.", function()
    sendEmote("wave")
end)

addCommand({ "cheer", "hooray" }, "Cheer.", function()
    sendEmote("cheer")
end)

addCommand({ "applaud", "clap" }, "Applaud.", function()
    sendEmote("applaud")
end)

addCommand({ "shrug", "idk", "confused" }, "Shrug.", function()
    sendEmote("shrug")
end)

addCommand({ "point", "pointout", "punch" }, "Point.", function()
    sendEmote("point")
end)

addCommand({ "laugh", "excite", "lol" }, "Laugh.", function()
    sendEmote("laugh")
end)

addCommand({ "emote", "e" }, "Run an emote.", function(_, ...)
    local emote = table.concat({ ... }, " ")

    if emote == "" then
        sendMessage("Usage: " .. PREFIX .. "emote <name>")
        return
    end

    sendEmote(emote)
end)

addCommand({ "reset", "kill", "oof", "die" }, "Reset managed accounts.", function()
    for _, entry in ipairs(getManagedBots()) do
        local bot = entry.player
        local humanoid = getHumanoid(bot)

        stopBotMovement(bot)

        if humanoid then
            humanoid.Health = 0
        end
    end
end)

addCommand({ "say", "chat", "message", "msg", "announce" }, "Send a chat message.", function(_, ...)
    if #getManagedBots() == 0 then
        return
    end

    local text = table.concat({ ... }, " ")

    if text ~= "" then
        sendMessage(text)
    end
end)

addCommand({ "ws", "walkspeed" }, "Set managed account WalkSpeed.", function(_, speedArg)
    local speed = tonumber(speedArg)

    if not speed or speed <= 0 then
        sendMessage("Please provide a valid positive number for speed.")
        return
    end

    for _, entry in ipairs(getManagedBots()) do
        local bot = entry.player
        local humanoid = getHumanoid(bot)

        if humanoid then
            local state = getBotState(bot)

            if state.defaultWalkSpeed == nil then
                state.defaultWalkSpeed = humanoid.WalkSpeed
            end

            humanoid.WalkSpeed = speed
            sendMessage(bot.Name .. "'s walk speed set to " .. speed .. ".")
        else
            sendMessage(bot.Name .. " does not have a humanoid.")
        end
    end
end)

addCommand({ "resetws", "defaultws" }, "Restore saved WalkSpeed.", function()
    for _, entry in ipairs(getManagedBots()) do
        local bot = entry.player
        local humanoid = getHumanoid(bot)
        local state = getBotState(bot)

        if humanoid and state.defaultWalkSpeed ~= nil then
            humanoid.WalkSpeed = state.defaultWalkSpeed
            sendMessage(bot.Name .. "'s walk speed reset to default.")
        else
            sendMessage("Cannot reset walk speed for " .. bot.Name .. ".")
        end
    end
end)

addCommand({ "stand" }, "Float behind the host.", function()
    if not getRoot(Host) then
        sendMessage("Host character is not ready.")
        return
    end

    local bots = getManagedBots()

    if #bots == 0 then
        sendMessage("No accounts available to stand.")
        return
    end

    for i, entry in ipairs(bots) do
        local bot = entry.player
        local token = beginBotMode(bot, "stand", Host)

        task.spawn(function()
            while isModeActive(bot, "stand", token) do
                local hostRoot = getRoot(Host)
                local botRoot = getRoot(bot)

                if hostRoot and botRoot then
                    -- Multiple accounts get spaced horizontally instead of
                    -- occupying exactly the same position.
                    local horizontal = (i - (#bots + 1) / 2) * 3
                    local base = hostRoot.CFrame * CFrame.new(horizontal, 2, 5)
                    local bob = math.sin(tick() * 2) * 0.5
                    local position = base.Position + Vector3.new(0, bob, 0)

                    botRoot.CFrame = CFrame.lookAt(
                        position,
                        hostRoot.Position
                    )
                end

                task.wait(0.05)
            end
        end)
    end
end)

addCommand({ "follow", "track", "watch" }, "Follow a player using pathfinding.", function(_, ...)
    local targetName = table.concat({ ... }, " ")
    local target = findPlayer(targetName)

    if not target then
        sendMessage("Target not found.")
        return
    end

    local bots = getManagedBots()

    if #bots == 0 then
        sendMessage("No accounts available to follow.")
        return
    end

    for _, entry in ipairs(bots) do
        local bot = entry.player
        local token = beginBotMode(bot, "follow", target)

        task.spawn(function()
            while isModeActive(bot, "follow", token) do
                local botRoot = getRoot(bot)
                local humanoid = getHumanoid(bot)
                local targetRoot = getRoot(target)

                if botRoot and humanoid and targetRoot then
                    local distance = (targetRoot.Position - botRoot.Position).Magnitude

                    -- Avoid constantly pathfinding while already close.
                    if distance > 5 then
                        local path = PathfindingService:CreatePath({
                            AgentCanJump = true,
                        })

                        local ok = pcall(function()
                            path:ComputeAsync(
                                botRoot.Position,
                                targetRoot.Position
                            )
                        end)

                        if ok and path.Status == Enum.PathStatus.Success then
                            local waypoints = path:GetWaypoints()

                            -- Move only toward the next useful waypoint.
                            -- The loop then recalculates for the moving target.
                            local waypoint = waypoints[2] or waypoints[1]

                            if waypoint then
                                if waypoint.Action == Enum.PathWaypointAction.Jump then
                                    humanoid.Jump = true
                                end

                                humanoid:MoveTo(waypoint.Position)
                            end
                        else
                            -- Simple fallback when pathfinding cannot produce a path.
                            humanoid:MoveTo(targetRoot.Position)
                        end
                    else
                        humanoid:MoveTo(botRoot.Position)
                    end
                end

                task.wait(0.25)
            end
        end)
    end
end)

addCommand({ "unfollow", "untrack", "unwatch", "standdown" }, "Stop follow/stand movement.", function()
    for _, entry in ipairs(getManagedBots()) do
        local state = getBotState(entry.player)

        if state.mode == "follow" or state.mode == "stand" then
            stopBotMovement(entry.player)
        end
    end
end)

addCommand({ "undance", "nodance", "nd", "stopdance" }, "Stop the current emote.", function()
    local humanoid = getHumanoid(LocalPlayer)

    if humanoid then
        humanoid.Jump = true
    end
end)

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
        sendMessage('Command "' .. commandName .. '" not found.')
        return
    end

    local ok, err = pcall(function()
        callback(unpack(args))
    end)

    if not ok then
        warn(
            "[Account Manager] Command failed:",
            commandName,
            err
        )
        sendMessage('Command "' .. commandName .. '" failed.')
    end
end

--// Host Listener

local function connectHostListener()
    if usingTextChatService() then
        TextChatService.MessageReceived:Connect(function(chatMessage)
            if not running then
                return
            end

            local source = chatMessage.TextSource

            if source and source.UserId == HOST_USER_ID then
                processCommand(chatMessage.Text)
            end
        end)
    else
        Host.Chatted:Connect(function(input)
            processCommand(input)
        end)
    end
end

--// Startup

if LocalPlayer.UserId == HOST_USER_ID then
    warn("[Account Manager] This script is meant to run on the ALT, not the MAIN.")
elseif not isManagedLocalAccount() then
    warn(
        "[Account Manager] This alt is not listed in ACCOUNTS. Local UserId:",
        LocalPlayer.UserId
    )
elseif Host then
    connectHostListener()

    sendMessage(
        "Account Manager v"
            .. VERSION
            .. " modified by Rafa loaded on "
            .. LocalPlayer.Name
            .. " in "
            .. string.format("%.2f", tick() - startedAt)
            .. " seconds."
    )
else
    warn(
        "[Account Manager] MAIN/host is not currently visible in this server. Host UserId:",
        HOST_USER_ID
    )
end
