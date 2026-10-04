--[[
    Account Manager v3.14
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
local VERSION = "3.14"
local STAND_ANIMATION_ID = "138791542100078"
local REPORT_ENDPOINT = "https://meowz.up.railway.app/api/account-manager"
local resolvedStandAnimationId = nil

local function resolveCatalogAnimation(catalogId)
    if resolvedStandAnimationId then
        return resolvedStandAnimationId
    end

    local ok, objects = pcall(function()
        return game:GetObjects("rbxassetid://" .. tostring(catalogId))
    end)

    if not ok or not objects or not objects[1] then
        warn("[Account Manager] Could not resolve catalog animation:", catalogId)
        return nil
    end

    local root = objects[1]
    local animation = root:IsA("Animation") and root or root:FindFirstChildWhichIsA("Animation", true)

    if animation and animation.AnimationId ~= "" then
        resolvedStandAnimationId = animation.AnimationId
        print("[Account Manager] Angel idle resolved to:", resolvedStandAnimationId)
    else
        warn("[Account Manager] Catalog item loaded, but no Animation object was found.")
    end

    pcall(function() root:Destroy() end)
    return resolvedStandAnimationId
end

local HOST_USER_ID = 3104567111
local ACCOUNTS = {
    9039839654, -- rafflesStorage1 / phone alt
}

--// Services

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TeleportService = game:GetService("TeleportService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

--// Runtime

local startedAt = tick()
-- LocalPlayer = the ALT on the phone executing this script.
-- Host        = the MAIN on the PC controlling the alt through chat.
local LocalPlayer = Players.LocalPlayer
local Host = Players:GetPlayerByUserId(HOST_USER_ID)

local function refreshHost()
    Host = Players:GetPlayerByUserId(HOST_USER_ID)
    return Host
end

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

-- Executor/Luau compatibility: some environments do not expose the old
-- global unpack(), which otherwise makes every command fail with
-- "attempt to call a nil value".
local unpackArgs = table.unpack or unpack

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
        return refreshHost()
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
            standAnimationTrack = nil,
            savedIdle1 = nil,
            savedIdle2 = nil,
            savedIdleWeight1 = nil,
            savedIdleWeight2 = nil,
            standObjects = nil,
        }
    end

    return botStates[userId]
end

local function cleanupStandConstraints(player)
    local state = getBotState(player)

    if state.standObjects then
        for _, object in ipairs(state.standObjects) do
            if object then
                pcall(function()
                    object:Destroy()
                end)
            end
        end
        state.standObjects = nil
    end
end

local function restoreStandIdle(player)
    local state = getBotState(player)
    local character = player and player.Character
    local animate = character and character:FindFirstChild("Animate")
    local idle = animate and animate:FindFirstChild("idle")
    local animation1 = idle and idle:FindFirstChild("Animation1")
    local animation2 = idle and idle:FindFirstChild("Animation2")

    if animation1 and state.savedIdle1 then
        animation1.AnimationId = state.savedIdle1
        local weight = animation1:FindFirstChild("Weight")
        if weight and state.savedIdleWeight1 ~= nil then
            weight.Value = state.savedIdleWeight1
        end
    end

    if animation2 and state.savedIdle2 then
        animation2.AnimationId = state.savedIdle2
        local weight = animation2:FindFirstChild("Weight")
        if weight and state.savedIdleWeight2 ~= nil then
            weight.Value = state.savedIdleWeight2
        end
    end

    state.savedIdle1 = nil
    state.savedIdle2 = nil
    state.savedIdleWeight1 = nil
    state.savedIdleWeight2 = nil

    -- Restart Animate so it immediately picks the restored idle.
    if animate then
        pcall(function()
            animate.Disabled = true
            task.wait()
            animate.Disabled = false
        end)
    end
end

local function stopBotMovement(player)
    local state = getBotState(player)

    state.token = state.token + 1
    state.mode = nil
    state.target = nil

    if state.standAnimationTrack then
        pcall(function()
            state.standAnimationTrack:Stop(0.2)
            state.standAnimationTrack:Destroy()
        end)
        state.standAnimationTrack = nil
    end

    cleanupStandConstraints(player)

    local humanoid = getHumanoid(player)
    if humanoid then
        humanoid:Move(Vector3.zero)
        humanoid.AutoRotate = true
    end
end

local function stopAllMovement()
    for _, entry in ipairs(getManagedBots()) do
        stopBotMovement(entry.player)
    end
end

local function beginBotMode(player, mode, target)
    local state = getBotState(player)

    if state.standAnimationTrack then
        pcall(function()
            state.standAnimationTrack:Stop(0.2)
            state.standAnimationTrack:Destroy()
        end)
        state.standAnimationTrack = nil
    end

    cleanupStandConstraints(player)

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
    local humanoid = getHumanoid(LocalPlayer)
    if not humanoid then
        warn("[Account Manager] Cannot emote: Humanoid not ready.")
        return false
    end

    local name = tostring(emote or "")
    if name == "" then
        return false
    end

    -- Play the emote directly on the phone alt. This avoids sending "/e ..."
    -- through TextChatService, which can show up as client-side command text.
    local ok, result = pcall(function()
        return humanoid:PlayEmote(name)
    end)

    if not ok or result == false then
        warn("[Account Manager] Could not play emote:", name, result)
        return false
    end

    return true
end

local function whisperHost(text)
    local hostPlayer = refreshHost()

    if not hostPlayer then
        warn("[Account Manager] Cannot whisper: host is not in the server.")
        return false
    end

    text = tostring(text)

    if usingTextChatService() then
        local channels = TextChatService:FindFirstChild("TextChannels")

        if not channels then
            warn("[Account Manager] TextChannels folder not found.")
            return false
        end

        local hostId = tostring(HOST_USER_ID)
        local altId = tostring(LocalPlayer.UserId)

        -- Find Roblox's actual private channel between MAIN and ALT.
        -- Confirmed in-game:
        -- RBXWhisper:3104567111_9039839654
        for _, channel in ipairs(channels:GetChildren()) do
            if channel:IsA("TextChannel")
                and string.sub(channel.Name, 1, 10) == "RBXWhisper"
                and string.find(channel.Name, hostId, 1, true)
                and string.find(channel.Name, altId, 1, true) then

                local ok, err = pcall(function()
                    channel:SendAsync(text)
                end)

                if ok then
                    print("[Account Manager] Private reply sent to " .. hostPlayer.Name)
                    return true
                end

                warn(
                    "[Account Manager] TextChatService whisper failed:",
                    err
                )

                return false
            end
        end

        warn(
            "[Account Manager] Whisper channel not found for",
            HOST_USER_ID,
            LocalPlayer.UserId
        )

        return false
    end

    -- Legacy fallback for games genuinely using LegacyChatService.
    local chatEvents =
        ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")

    local sayRequest =
        chatEvents and chatEvents:FindFirstChild("SayMessageRequest")

    if sayRequest and sayRequest:IsA("RemoteEvent") then
        local ok, err = pcall(function()
            sayRequest:FireServer(
                text,
                "To " .. hostPlayer.Name
            )
        end)

        if not ok then
            warn(
                "[Account Manager] Legacy whisper failed:",
                err
            )
        end

        return ok
    end

    return false
end

local function replyToHost(text)
    -- All command/status feedback is private by default.
    -- Only commands that intentionally call sendMessage(), such as ,say,
    -- should speak publicly.
    if not whisperHost(tostring(text)) then
        warn("[Account Manager -> Host] " .. tostring(text))
    end
end


local executorRequest = request or http_request

local function reportToDiscord(commandName, data)
    if type(executorRequest) ~= "function" then
        warn("[Account Manager] Executor HTTP request API is unavailable.")
        return false
    end

    data = data or {}
    data.command = commandName
    data.version = VERSION
    data.alt = LocalPlayer.Name
    data.altUserId = LocalPlayer.UserId
    data.hostUserId = HOST_USER_ID

    local hostPlayer = refreshHost()
    data.host = hostPlayer and hostPlayer.Name or "missing"

    local ok, response = pcall(function()
        return executorRequest({
            Url = REPORT_ENDPOINT,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(data),
        })
    end)

    if not ok then
        warn("[Account Manager] Discord report request failed:", response)
        return false
    end

    local statusCode = tonumber(response and (response.StatusCode or response.Status))
    if statusCode and statusCode >= 200 and statusCode < 300 then
        print("[Account Manager] Sent " .. commandName .. " to Discord.")
        return true
    end

    warn("[Account Manager] Discord report rejected:", statusCode or "unknown", response and response.Body or "")
    return false
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

addCommand({ "help", "cmds", "commands" }, "Send the command list to Discord.", function()
    if reportToDiscord("help") then
        return
    end

    local lines = {
        "=== Account Manager v" .. VERSION .. " ===",
        ",bring | ,line <left/right/front/back>",
        ",follow [player] | ,unfollow",
        ",stand | ,standdown",
        ",orbit [player] [speed] [radius] | ,unorbit",
        ",ws <speed> | ,resetws",
        ",dance [1/2/3] | ,undance",
        ",wave | ,cheer | ,laugh | ,point",
        ",applaud | ,shrug | ,emote <name>",
        ",say <message> | ,reset | ,rejoin",
        ",index | ,promo | ,animid | ,meatballify | ,end",
    }

    for _, line in ipairs(lines) do
        if not whisperHost(line) then
            warn("[Account Manager] Could not whisper help to host.")
            return
        end
        task.wait(0.15)
    end
end)

addCommand({ "animid", "standanim" }, "Resolve the Angel stand animation ID.", function()
    local id = resolveCatalogAnimation(STAND_ANIMATION_ID)
    if id then
        print("[Account Manager] Angel actual animation:", id)
        replyToHost("Angel actual animation: " .. tostring(id))
    end
end)

addCommand({ "chattest", "ct" }, "Whisper a legacy-chat diagnostic back to the host.", function()
    local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    local filtered = chatEvents and chatEvents:FindFirstChild("OnMessageDoneFiltering")
    local say = chatEvents and chatEvents:FindFirstChild("SayMessageRequest")

    replyToHost(
        "Chat=" .. tostring(TextChatService.ChatVersion) .. " | Listener=" .. (usingTextChatService() and "MessageReceived" or "Host.Chatted")
        .. " | Events=" .. tostring(chatEvents ~= nil)
        .. " | Filtered=" .. tostring(filtered ~= nil)
        .. " | Say=" .. tostring(say ~= nil)
    )
end)

addCommand({ "status", "check" }, "Send Account Manager runtime status to Discord.", function()
    local hostPlayer = refreshHost()
    local _, humanoid, root = getCharacter(LocalPlayer)
    local state = getBotState(LocalPlayer)
    local payload = {
        characterReady = root ~= nil and humanoid ~= nil,
        chat = tostring(TextChatService.ChatVersion),
        mode = tostring(state.mode or "none"),
    }

    if not reportToDiscord("status", payload) then
        replyToHost(
            "AM v" .. VERSION
            .. " | alt=" .. LocalPlayer.Name .. " (" .. LocalPlayer.UserId .. ")"
            .. " | host=" .. (hostPlayer and hostPlayer.Name or "missing")
            .. " | char=" .. tostring(payload.characterReady)
            .. " | chat=" .. payload.chat .. " | mode=" .. payload.mode
        )
    end
end)

addCommand({ "ex", "example", "debug" }, "Show command response time.", function()
    replyToHost(
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
    local hostRoot = getRoot(refreshHost())

    if not hostRoot then
        replyToHost("Host character is not ready.")
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
    local hostRoot = getRoot(refreshHost())

    if not hostRoot then
        replyToHost("Host character is not ready.")
        return
    end

    if direction == "" then
        replyToHost("Usage: " .. PREFIX .. "line <left/right/front/back>")
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
                replyToHost("Unknown line direction: " .. direction)
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
        replyToHost("Target not found.")
        return
    end

    if radius <= 0 then
        replyToHost("Radius must be greater than 0.")
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

addCommand({ "index", "ingame", "online" }, "Send managed-account count to Discord.", function()
    local count = #getManagedBots()
    if not reportToDiscord("index", { count = count }) then
        replyToHost("Managing " .. count .. " accounts.")
    end
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
        replyToHost("Meatballify failed to load.")
    end
end)

addCommand({ "end", "stop", "quit", "exit", "close" }, "Disable Account Manager commands.", function()
    stopAllMovement()
    running = false
    replyToHost("Account Manager successfully closed.")
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
        replyToHost("Usage: " .. PREFIX .. "emote <name>")
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
        replyToHost("Please provide a valid positive number for speed.")
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
            replyToHost(bot.Name .. "'s walk speed set to " .. speed .. ".")
        else
            replyToHost(bot.Name .. " does not have a humanoid.")
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
            replyToHost(bot.Name .. "'s walk speed reset to default.")
        else
            replyToHost("Cannot reset walk speed for " .. bot.Name .. ".")
        end
    end
end)

addCommand({ "stand" }, "Float behind the host.", function()
    if not getRoot(refreshHost()) then
        replyToHost("Host character is not ready.")
        return
    end

    local bots = getManagedBots()

    if #bots == 0 then
        replyToHost("No accounts available to stand.")
        return
    end

    for i, entry in ipairs(bots) do
        local bot = entry.player
        local token = beginBotMode(bot, "stand", refreshHost())

        local humanoid = getHumanoid(bot)
        local state = getBotState(bot)

        if humanoid then
            local actualAnimationId = resolveCatalogAnimation(STAND_ANIMATION_ID)

            if actualAnimationId then
                local animator = humanoid:FindFirstChildOfClass("Animator")
                if not animator then
                    animator = humanoid:WaitForChild("Animator", 3)
                end

                if animator then
                    local animation = Instance.new("Animation")
                    animation.AnimationId = actualAnimationId

                    local ok, track = pcall(function()
                        return animator:LoadAnimation(animation)
                    end)
                    animation:Destroy()

                    if ok and track then
                        track.Looped = true
                        track.Priority = Enum.AnimationPriority.Action
                        state.standAnimationTrack = track
                        track:Play(0.2, 1, 1)
                    else
                        warn("[Account Manager] Resolved Angel idle but Roblox refused it:", track)
                    end
                end
            end
        end

        -- Smooth stand: physics constraints continuously pull the alt to an
        -- attachment behind the host instead of repeatedly teleporting it.
        local botRoot = getRoot(bot)
        local hostRoot = getRoot(refreshHost())

        if botRoot and hostRoot then
            local botAttachment = Instance.new("Attachment")
            botAttachment.Name = "AccountManagerStandBot"
            botAttachment.Parent = botRoot

            local targetAttachment = Instance.new("Attachment")
            targetAttachment.Name = "AccountManagerStandTarget"
            targetAttachment.Position = Vector3.new(0, 1.75, 5)
            targetAttachment.Parent = hostRoot

            local alignPosition = Instance.new("AlignPosition")
            alignPosition.Name = "AccountManagerStandPosition"
            alignPosition.Attachment0 = botAttachment
            alignPosition.Attachment1 = targetAttachment
            alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
            alignPosition.ApplyAtCenterOfMass = true
            alignPosition.MaxForce = 1000000
            alignPosition.MaxVelocity = 45
            alignPosition.Responsiveness = 22
            alignPosition.RigidityEnabled = false
            alignPosition.Parent = botRoot

            local alignOrientation = Instance.new("AlignOrientation")
            alignOrientation.Name = "AccountManagerStandOrientation"
            alignOrientation.Attachment0 = botAttachment
            alignOrientation.Attachment1 = targetAttachment
            alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
            alignOrientation.MaxTorque = 1000000
            alignOrientation.MaxAngularVelocity = 35
            alignOrientation.Responsiveness = 18
            alignOrientation.RigidityEnabled = false
            alignOrientation.Parent = botRoot

            state.standObjects = {
                alignPosition,
                alignOrientation,
                botAttachment,
                targetAttachment,
            }

            local h = getHumanoid(bot)
            if h then
                h.AutoRotate = false
            end

            task.spawn(function()
                while isModeActive(bot, "stand", token) do
                    local currentBotRoot = getRoot(bot)
                    local currentHostRoot = getRoot(refreshHost())

                    -- Only teleport as emergency recovery if physics leaves the
                    -- alt extremely far away. Normal following stays smooth.
                    if currentBotRoot and currentHostRoot then
                        local desired = currentHostRoot.CFrame * CFrame.new(0, 1.75, 5)
                        if (currentBotRoot.Position - desired.Position).Magnitude > 45 then
                            currentBotRoot.CFrame = desired
                            currentBotRoot.AssemblyLinearVelocity = Vector3.zero
                            currentBotRoot.AssemblyAngularVelocity = Vector3.zero
                        end
                    end

                    task.wait(0.25)
                end

                cleanupStandConstraints(bot)

                local currentHumanoid = getHumanoid(bot)
                if currentHumanoid then
                    currentHumanoid.AutoRotate = true
                end
            end)
        else
            warn("[Account Manager] Could not create smooth stand constraints.")
        end
    end
end)

addCommand({ "follow", "track", "watch" }, "Follow a player using pathfinding.", function(_, ...)
    local targetName = table.concat({ ... }, " ")
    local target = findPlayer(targetName)

    if not target then
        replyToHost("Target not found.")
        return
    end

    local bots = getManagedBots()

    if #bots == 0 then
        replyToHost("No accounts available to follow.")
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

--// Host Listener

local hostChatConnection = nil

local function connectHostListener()
    if hostChatConnection then
        pcall(function()
            hostChatConnection:Disconnect()
        end)
        hostChatConnection = nil
    end

    if usingTextChatService() then
        TextChatService.MessageReceived:Connect(function(chatMessage)
            local source = chatMessage.TextSource
            if not source or source.UserId ~= HOST_USER_ID then
                return
            end

            local input = tostring(chatMessage.Text or "")
            if input:sub(1, #PREFIX) == PREFIX then
                processCommand(input)
            end
        end)

        print("[Account Manager] TextChatService host listener connected.")
        return true
    end

    -- LegacyChatService:
    -- Host.Chatted was tested directly in this experience and receives
    -- the host's public chat messages reliably.
    local hostPlayer = refreshHost()
    if not hostPlayer then
        warn("[Account Manager] Host is not present; waiting for host to join.")
        return false
    end

    hostChatConnection = hostPlayer.Chatted:Connect(function(input)
        input = tostring(input or "")

        if input:sub(1, #PREFIX) == PREFIX then
            print("[Account Manager] Command from host:", input)
            processCommand(input)
        end
    end)

    print("[Account Manager] Legacy Host.Chatted listener connected to " .. hostPlayer.Name .. ".")
    return true
end

-- Keep Host current if the main leaves/rejoins the same server.
Players.PlayerAdded:Connect(function(player)
    if player.UserId == HOST_USER_ID then
        Host = player
        print("[Account Manager] Host joined: " .. player.Name)

        if not usingTextChatService() then
            task.defer(function()
                connectHostListener()
            end)
        end
    end
end)

Players.PlayerRemoving:Connect(function(player)
    if player.UserId == HOST_USER_ID then
        Host = nil
        stopAllMovement()
    end
end)

--// Startup

if type(unpackArgs) ~= "function" then
    error("[Account Manager] No table.unpack/unpack implementation is available.")
end


if LocalPlayer.UserId == HOST_USER_ID then
    warn("[Account Manager] This script is meant to run on the ALT, not the MAIN.")
elseif not isManagedLocalAccount() then
    warn(
        "[Account Manager] This alt is not listed in ACCOUNTS. Local UserId:",
        LocalPlayer.UserId,
        "Expected:",
        table.concat(ACCOUNTS, ", ")
    )
else
    -- TextChatService listener filters by HOST_USER_ID, so it can be connected
    -- even if the main has not fully appeared in Players at this exact instant.
    local listenerConnected = connectHostListener()
    print("[Account Manager] v" .. VERSION .. " startup complete | listener=" .. tostring(listenerConnected))

    local hostNow = refreshHost()
    if hostNow then
        replyToHost(
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
            "[Account Manager] Loaded successfully, but the MAIN is not visible yet. Waiting for UserId:",
            HOST_USER_ID
        )
    end
end
