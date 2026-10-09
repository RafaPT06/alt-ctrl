--[[
    Account Manager v3.24.2
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
local VERSION = "3.24.2"
local STAND_ANIMATION_ID = "138791542100078"
local GUARD_IDLE_ANIMATION_ID = "83061898886380"
local GUARD_WALK_ANIMATION_ID = "98105137336279"
local GUARD_RUN_ANIMATION_ID = "88321834888120"
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
local shutdownRuntime = nil
local runtimeEnvironment = _G
if type(getgenv) == "function" then
    local ok, environment = pcall(getgenv)
    if ok and type(environment) == "table" then runtimeEnvironment = environment end
end
local RUNTIME_KEY = "__AccountManagerRuntime"
local runtimeHandle = nil
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
            guardStyle = "tactical",
            guardPoseJoints = nil,
            guardAnimationTracks = nil,
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

local function cleanupFunMovement(player)
    local state = getBotState(player)
    local humanoid = state.funHumanoid
    if humanoid and humanoid.Parent then
        if state.funAutoRotate ~= nil then humanoid.AutoRotate = state.funAutoRotate end
        if state.funSitting then humanoid.Sit = false end
        humanoid:Move(Vector3.zero)
    end
    state.funHumanoid = nil
    state.funAutoRotate = nil
    state.funSitting = nil
end

local function clearGuardPose(player)
    local state = getBotState(player)
    if state.guardPoseJoints then
        for joint, original in pairs(state.guardPoseJoints) do
            if joint and joint.Parent then
                pcall(function() joint.Transform = original end)
            end
        end
        state.guardPoseJoints = nil
    end
end

local function setGuardPose(player, enabled)
    local state = getBotState(player)
    if not enabled or state.guardStyle ~= "tactical" then
        clearGuardPose(player)
        return
    end
    local character = player and player.Character
    if not character then return end
    if not state.guardPoseJoints then state.guardPoseJoints = {} end
    local joints = state.guardPoseJoints
    local right = character:FindFirstChild("RightShoulder", true) or character:FindFirstChild("Right Shoulder", true)
    local left = character:FindFirstChild("LeftShoulder", true) or character:FindFirstChild("Left Shoulder", true)
    if right and right:IsA("Motor6D") then
        if joints[right] == nil then joints[right] = right.Transform end
        right.Transform = CFrame.Angles(math.rad(-18), 0, math.rad(10))
    end
    if left and left:IsA("Motor6D") then
        if joints[left] == nil then joints[left] = left.Transform end
        left.Transform = CFrame.Angles(math.rad(-12), 0, math.rad(-12))
    end
end

local function stopGuardAnimations(player)
    local state = getBotState(player)
    if state.guardAnimationTracks then
        for _, track in pairs(state.guardAnimationTracks) do
            if track then
                pcall(function()
                    track:Stop(0.15)
                    track:Destroy()
                end)
            end
        end
        state.guardAnimationTracks = nil
    end
end

local function loadGuardAnimations(player)
    stopGuardAnimations(player)
    local humanoid = getHumanoid(player)
    if not humanoid then return nil end
    local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 3)
    if not animator then return nil end

    local tracks = {}
    local ids = {
        idle = GUARD_IDLE_ANIMATION_ID,
        walk = GUARD_WALK_ANIMATION_ID,
        run = GUARD_RUN_ANIMATION_ID,
    }
    for name, id in pairs(ids) do
        local animation = Instance.new("Animation")
        animation.AnimationId = "rbxassetid://" .. id
        local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
        animation:Destroy()
        if ok and track then
            track.Looped = true
            track.Priority = Enum.AnimationPriority.Action
            tracks[name] = track
        else
            warn("[Account Manager] Could not load guard " .. name .. " animation:", track)
        end
    end
    getBotState(player).guardAnimationTracks = tracks
    return tracks
end

local function playGuardAnimation(player, name)
    local state = getBotState(player)
    if state.guardStyle ~= "tactical" then
        stopGuardAnimations(player)
        return
    end
    local tracks = state.guardAnimationTracks or loadGuardAnimations(player)
    if not tracks then return end
    for trackName, track in pairs(tracks) do
        if trackName == name then
            if not track.IsPlaying then track:Play(0.15, 1, 1) end
        elseif track.IsPlaying then
            track:Stop(0.15)
        end
    end
end

local function movementBlocked(player, destination)
    local root = getRoot(player)
    if not root then return false end
    local delta = destination - root.Position
    if delta.Magnitude < 3 then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = {}
    for _, other in ipairs(Players:GetPlayers()) do
        if other.Character then table.insert(excluded, other.Character) end
    end
    params.FilterDescendantsInstances = excluded
    return workspace:Raycast(root.Position + Vector3.new(0, 1.5, 0), delta.Unit * math.min(delta.Magnitude, 8), params) ~= nil
end

local isModeActive

local function startNaturalFollow(player, mode, target, offset, stopRadius, token, useGuardPose)
    task.spawn(function()
        local lastPosition = nil
        local lastProgressAt = tick()
        local pathWaypoints = nil
        local pathIndex = 1
        local pathExpires = 0

        while isModeActive(player, mode, token) do
            local root, humanoid, targetRoot = getRoot(player), getHumanoid(player), getRoot(target)
            if root and humanoid and targetRoot then
                humanoid.AutoRotate = true
                local desired = targetRoot.CFrame * offset
                local distance = (root.Position - desired.Position).Magnitude

                if distance > 90 then
                    if useGuardPose then playGuardAnimation(player, "run") end
                    root.CFrame = desired
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    pathWaypoints = nil
                    lastPosition = root.Position
                    lastProgressAt = tick()
                elseif distance <= stopRadius then
                    humanoid:Move(Vector3.zero)
                    pathWaypoints = nil
                    if useGuardPose then playGuardAnimation(player, "idle") end
                else
                    if useGuardPose then
                        local speed = root.AssemblyLinearVelocity.Magnitude
                        playGuardAnimation(player, speed >= 14 and "run" or "walk")
                    end
                    local now = tick()
                    if not lastPosition then
                        lastPosition = root.Position
                        lastProgressAt = now
                    elseif (root.Position - lastPosition).Magnitude >= 1.25 then
                        lastPosition = root.Position
                        lastProgressAt = now
                    end

                    local stuck = now - lastProgressAt > 1.0
                    local blocked = movementBlocked(player, desired.Position)
                    if (stuck or blocked) and (not pathWaypoints or now >= pathExpires) then
                        local path = PathfindingService:CreatePath({ AgentCanJump = true })
                        local ok = pcall(function() path:ComputeAsync(root.Position, desired.Position) end)
                        if ok and path.Status == Enum.PathStatus.Success then
                            pathWaypoints = path:GetWaypoints()
                            pathIndex = math.min(2, #pathWaypoints)
                            pathExpires = now + 1.5
                            lastProgressAt = now
                        else
                            pathWaypoints = nil
                        end
                    end

                    local waypoint = pathWaypoints and pathWaypoints[pathIndex]
                    if waypoint and now < pathExpires then
                        if (root.Position - waypoint.Position).Magnitude < 2.5 then
                            pathIndex = pathIndex + 1
                            waypoint = pathWaypoints[pathIndex]
                        end
                        if waypoint then
                            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                            humanoid:MoveTo(waypoint.Position)
                        else
                            pathWaypoints = nil
                            humanoid:MoveTo(desired.Position)
                        end
                    else
                        pathWaypoints = nil
                        humanoid:MoveTo(desired.Position)
                    end
                end
            else
                if useGuardPose then stopGuardAnimations(player) end
            end
            task.wait(0.2)
        end
        if useGuardPose then stopGuardAnimations(player) end
    end)
end

local function stopBotMovement(player)
    cleanupFunMovement(player)
    clearGuardPose(player)
    stopGuardAnimations(player)
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
    cleanupFunMovement(player)
    clearGuardPose(player)
    stopGuardAnimations(player)
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

isModeActive = function(player, mode, token)
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

addCommand({ "help", "cmds", "commands" }, "Show commands. Usage: ,help [page or command]", function(_, query)
    local names = {}
    local entries = {}
    for name in pairs(commandInfo) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local info = commandInfo[name]
        table.insert(entries, {
            command = PREFIX .. name,
            aliases = info.aliases,
            description = info.description,
        })
    end

    if query and not tonumber(query) then
        local wanted = string.lower(query):gsub("^,", "")
        for _, name in ipairs(names) do
            local info = commandInfo[name]
            for _, alias in ipairs(info.aliases) do
                if alias == wanted then
                    replyToHost(PREFIX .. name .. ": " .. info.description)
                    replyToHost("Aliases: " .. PREFIX .. table.concat(info.aliases, " " .. PREFIX))
                    return
                end
            end
        end
        replyToHost("Unknown command. Use ,help or ,help <page>.")
        return
    end

    local pageSize = 8
    local pages = math.max(1, math.ceil(#names / pageSize))
    local page = tonumber(query) or 1
    if page ~= page or page % 1 ~= 0 or page < 1 or page > pages then
        replyToHost("Help page must be a whole number from 1 to " .. pages .. ".")
        return
    end
    -- Include the current registry for report consumers; always show private help too.
    if not query then reportToDiscord("help", { commands = entries }) end
    replyToHost("AM v" .. VERSION .. " commands (" .. page .. "/" .. pages .. ")")
    for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #names) do
        local name = names[index]
        replyToHost(PREFIX .. name .. ": " .. commandInfo[name].description)
        task.wait(0.2)
    end
    replyToHost("Use ,help <page> or ,help <command> for usage and aliases.")
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
    if shutdownRuntime then shutdownRuntime() end
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

addCommand({ "follow", "track", "watch" }, "Naturally follow about 5 studs behind a player.", function(_, ...)
    local targetName = table.concat({ ... }, " ")
    local target = findPlayer(targetName)
    if not target then replyToHost("Target not found.") return end
    local bots = getManagedBots()
    if #bots == 0 then replyToHost("No accounts available to follow.") return end
    for _, entry in ipairs(bots) do
        local bot = entry.player
        local token = beginBotMode(bot, "follow", target)
        startNaturalFollow(bot, "follow", target, CFrame.new(0, 0, 5), 2.75, token, false)
    end
end)

addCommand({ "unfollow", "untrack", "unwatch", "standdown" }, "Stop follow/stand movement.", function()
    for _, entry in ipairs(getManagedBots()) do
        local state = getBotState(entry.player)
        if state.mode == "follow" or state.mode == "stand" then stopBotMovement(entry.player) end
    end
end)

--// Flex commands

local function resolveTargetFromArgs(...)
    local query = table.concat({ ... }, " ")
    local target = findPlayer(query)
    if not target then
        replyToHost("Target not found.")
    end
    return target
end

local godModeEnabled = false
local godConnection = nil

local function applyGodMode()
    local character = LocalPlayer.Character
    local humanoid = getHumanoid(LocalPlayer)
    if not character or not humanoid then return end

    -- Natural Disaster Survival historically creates a local fall-damage
    -- controller named FallDamageScript. Remove it whenever it is present.
    local fallDamage = character:FindFirstChild("FallDamageScript", true)
    if fallDamage then
        pcall(function() fallDamage:Destroy() end)
    end

    pcall(function()
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        humanoid.MaxHealth = math.huge
        humanoid.Health = math.huge
    end)
end

addCommand({ "god", "godmode" }, "NDS-focused damage protection and continuous health restore.", function()
    godModeEnabled = true
    applyGodMode()

    if godConnection then godConnection:Disconnect() end
    godConnection = LocalPlayer.CharacterAdded:Connect(function()
        if running and godModeEnabled then
            task.wait(0.5)
            if running and godModeEnabled then applyGodMode() end
        end
    end)

    task.spawn(function()
        while running and godModeEnabled do
            applyGodMode()
            task.wait(0.05)
        end
    end)
end)

addCommand({ "ungod", "nogod" }, "Disable god mode.", function()
    godModeEnabled = false
    if godConnection then
        godConnection:Disconnect()
        godConnection = nil
    end

    local humanoid = getHumanoid(LocalPlayer)
    if humanoid then
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
            humanoid.MaxHealth = 100
            humanoid.Health = math.min(humanoid.Health, 100)
        end)
    end
end)

local ringEnabled = false
local ringRadius = 50
local ringSpeed = 0.5
local ringHeight = 100
local ringLimit = 80
local ringParts = {}
local ringConnections = {}
local ringCandidates = {}
local ringCandidateCount = 0
local ringRetryAt = setmetatable({}, { __mode = "k" })
local ringCharacters = {}
local ringOverlap = nil
local ringCell = 4
local ringCount = 0
local ringGeneration = 0
local ringWatch = {}
local ringWatchCount = 0
local ringStats = { scanned = 0, rejected = 0, stalled = 0 }
local ringLastError = nil
local ringControl = nil
local ringControlStatus = "not started"
local RING_INTERVAL = 1 / 25
local RING_DISCOVERY_RADIUS = 120
local RING_RELEASE_DISTANCE = 240
local RING_CANDIDATE_LIMIT = 512
local RING_ATTRACTION_SPEED = 1000
local ringPhysicalProperties = PhysicalProperties.new(0.01, 0, 0, 0, 0)
-- Optional executor API; ordinary clients fall back to a movement check.
local ringOwnerCheck = type(isnetworkowner) == "function" and isnetworkowner or nil

local function isRingPart(part, allowAnchored)
    if not part:IsA("BasePart") or not part:IsDescendantOf(workspace)
        or (part.Anchored and not allowAnchored) or part.Size.Magnitude > 45 then return false end
    local assembly = part.AssemblyRootPart
    if not assembly or (assembly.Anchored and not allowAnchored) then return false end
    local ancestor = part.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Accessory") or ancestor:IsA("Tool")
            or (ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid"))
            or (ancestor:IsA("Model") and Players:GetPlayerFromCharacter(ancestor)) then return false end
        ancestor = ancestor.Parent
    end
    return true
end

local function removeRingPart(part, retry)
    local entry = ringParts[part]
    if not entry then return end
    ringParts[part] = nil
    ringCount = ringCount - 1
    for affected, original in pairs(entry.originals) do
        pcall(function()
            affected.CanCollide = original.canCollide
            affected.CustomPhysicalProperties = original.physicalProperties
        end)
    end
    -- Release the velocity we applied, without restoring an old launch velocity.
    pcall(function()
        if part:IsDescendantOf(workspace) and not part.Anchored then
            part.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    if retry then ringRetryAt[part] = tick() + 10 end
end

local function refreshRingControl()
    if not ringControl then return end
    if ringControl.radiusSaved then
        local ok = pcall(sethiddenproperty, LocalPlayer, "SimulationRadius", RING_RELEASE_DISTANCE)
        if not ok then ringControlStatus = "radius update failed" end
    end
end

local function beginRingControl()
    ringControl = {}
    -- The reference uses infinite range; keep acquisition local and reversible.
    if type(sethiddenproperty) == "function" then
        local ok, radius = pcall(function()
            if type(gethiddenproperty) == "function" then
                return gethiddenproperty(LocalPlayer, "SimulationRadius")
            end
            return LocalPlayer.SimulationRadius
        end)
        if ok and type(radius) == "number" then
            ringControl.radiusSaved = true
            ringControl.radius = radius
        end
    end
    local ok, focus = pcall(function() return LocalPlayer.ReplicationFocus end)
    if ok then
        ringControl.focus = focus
        ringControl.focusSaved = pcall(function() LocalPlayer.ReplicationFocus = getRoot(LocalPlayer) end)
    end
    ringControlStatus = ringControl.radiusSaved and "local control requested" or "simulation API unavailable"
    refreshRingControl()
end

local function restoreRingControl()
    if not ringControl then return end
    if ringControl.radiusSaved then
        pcall(sethiddenproperty, LocalPlayer, "SimulationRadius", ringControl.radius)
    end
    if ringControl.focusSaved then
        pcall(function() LocalPlayer.ReplicationFocus = ringControl.focus end)
    end
    ringControl = nil
end

local function stopRing()
    ringEnabled = false
    ringGeneration = ringGeneration + 1
    for _, connection in ipairs(ringConnections) do connection:Disconnect() end
    ringConnections = {}
    for part in pairs(ringParts) do removeRingPart(part) end
    ringCandidates = {}
    ringCandidateCount = 0
    ringRetryAt = setmetatable({}, { __mode = "k" })
    ringCharacters = {}
    ringOverlap = nil
    ringCell = 4
    ringWatch = {}
    ringWatchCount = 0
    restoreRingControl()
end

local function queueRingPart(part)
    if not ringEnabled or not part:IsA("BasePart") then return end
    -- One set of movers per assembly, rather than per welded piece.
    part = part.AssemblyRootPart or part
    if ringParts[part] or ringCandidates[part]
        or (ringRetryAt[part] or 0) > tick() then return end
    local root = getRoot(LocalPlayer)
    if not root or not isRingPart(part)
        or (part.Position - root.Position).Magnitude > RING_DISCOVERY_RADIUS then return end
    if ringCandidateCount < RING_CANDIDATE_LIMIT then
        ringCandidates[part] = true
        ringCandidateCount = ringCandidateCount + 1
    end
end

local function trackRingPart(part)
    if not ringEnabled or not part:IsA("BasePart") then return end
    local root = getRoot(LocalPlayer)
    if not root or not isRingPart(part, true)
        or (part.Position - root.Position).Magnitude > RING_DISCOVERY_RADIUS then return end
    if not ringWatch[part] and ringWatchCount < RING_CANDIDATE_LIMIT then
        ringWatch[part] = true
        ringWatchCount = ringWatchCount + 1
    end
    queueRingPart(part)
end

local function ownsRingPart(part)
    if not ringOwnerCheck then return true end
    local ok, owned = pcall(ringOwnerCheck, part)
    if not ok then
        ringOwnerCheck = nil
        return true
    end
    return owned == true
end

local function addRingPart(part, now)
    if ringParts[part] or ringCount >= ringLimit or not isRingPart(part) then return end
    local connected = part:GetConnectedParts(true)
    table.insert(connected, part)
    -- Keep all player/accessory exclusions, including welded assemblies.
    for _, affected in ipairs(connected) do
        if not isRingPart(affected) then return end
    end
    -- Give automatic ownership a chance after local control is requested.
    local entry = {
        originals = {}, checkAt = now + 6, lastPosition = part.Position, travelled = 0,
        target = part.Position, expectedSpeed = 0,
    }
    ringParts[part] = entry
    ringCount = ringCount + 1
    local ok, setupError = pcall(function()
        for _, affected in ipairs(connected) do
            if not entry.originals[affected] then
                entry.originals[affected] = {
                    canCollide = affected.CanCollide,
                    physicalProperties = affected.CustomPhysicalProperties,
                }
                affected.CanCollide = false
                affected.CustomPhysicalProperties = ringPhysicalProperties
            end
        end
    end)
    if not ok then
        ringLastError = "Debris setup: " .. tostring(setupError)
        removeRingPart(part, true)
    end
end

-- Motion adapted from the user's Lil0darkie6 Rings v8 reference.
-- Speed is radians/second rather than a frame-dependent degree increment.
local function getSuperRingTarget(position, center, step)
    local dx = position.X - center.X
    local dz = position.Z - center.Z
    local distance = math.sqrt(dx * dx + dz * dz)
    local angle = math.atan2(dz, dx) + ringSpeed * step
    local radius = math.min(ringRadius, distance)
    return Vector3.new(
        center.X + math.cos(angle) * radius,
        center.Y + ringHeight * math.abs(math.sin((position.Y - center.Y) / ringHeight)),
        center.Z + math.sin(angle) * radius
    )
end

local function getSuperRingVelocity(position, target, step)
    local difference = target - position
    local distance = difference.Magnitude
    -- The reference normalizes zero vectors; guard that and avoid 25 Hz overshoot.
    if distance < 0.001 then return Vector3.zero end
    local speed = math.min(RING_ATTRACTION_SPEED, distance / math.max(step, RING_INTERVAL))
    return difference.Unit * speed
end

local function ringNumber(value, default, minimum, maximum)
    local number = tonumber(value)
    if not number or number ~= number or math.abs(number) == math.huge then return default end
    return math.clamp(number, minimum, maximum)
end

local function discoverRingParts(root, now)
    refreshRingControl()
    for part in pairs(ringWatch) do
        if not isRingPart(part, true) or (part.Position - root.Position).Magnitude > RING_DISCOVERY_RADIUS then
            ringWatch[part] = nil
            ringWatchCount = ringWatchCount - 1
        else
            queueRingPart(part)
        end
    end
    ringCharacters = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then table.insert(ringCharacters, player.Character) end
    end
    -- Exclude active assemblies from capped queries so they do not consume results.
    local excluded = {}
    for _, character in ipairs(ringCharacters) do table.insert(excluded, character) end
    for part in pairs(ringParts) do table.insert(excluded, part) end
    ringOverlap.FilterDescendantsInstances = excluded
    -- Rotate nine local cells, with at most 128 results per discovery tick.
    -- This also finds existing anchored map parts after they become loose.
    local x = (ringCell % 3) - 1
    local z = math.floor(ringCell / 3) - 1
    ringCell = (ringCell + 1) % 9
    local center = root.Position + Vector3.new(x * 80, 0, z * 80)
    for _, part in ipairs(workspace:GetPartBoundsInBox(
        CFrame.new(center), Vector3.new(80, 240, 80), ringOverlap
    )) do trackRingPart(part) end

    local ranked = {}
    for part in pairs(ringCandidates) do
        ringCandidates[part] = nil
        ringCandidateCount = ringCandidateCount - 1
        if isRingPart(part) and (ringRetryAt[part] or 0) <= now then
            local distance = (part.Position - root.Position).Magnitude
            if distance <= RING_DISCOVERY_RADIUS then
                table.insert(ranked, {
                    part = part,
                    -- Distance dominates; larger debris wins within nearby groups.
                    score = distance - math.min(part.Size.Magnitude, 30) * 0.5,
                })
            end
        end
    end
    table.sort(ranked, function(a, b) return a.score < b.score end)
    for index, candidate in ipairs(ranked) do
        if ringCount >= ringLimit or index > 32 then break end
        addRingPart(candidate.part, now)
    end
end

addCommand({ "ring", "superring" }, "Super-ring debris swirl. Usage: ,ring [radius] [speed] [height]", function(_, radiusArg, speedArg, heightArg)
    ringRadius = ringNumber(radiusArg, ringRadius, 6, 100)
    ringSpeed = ringNumber(speedArg, ringSpeed, 0.2, 12)
    ringHeight = ringNumber(heightArg, ringHeight, 10, 150)
    if ringEnabled then replyToHost("Ring settings updated. Use ,ringstatus to check debris.") return end
    if not getRoot(LocalPlayer) then replyToHost("Ring: character is not ready.") return end
    ringEnabled = true
    ringGeneration = ringGeneration + 1
    local generation = ringGeneration
    ringStats = { scanned = 0, rejected = 0, stalled = 0 }
    ringLastError = nil
    beginRingControl()
    ringOverlap = OverlapParams.new()
    ringOverlap.FilterType = Enum.RaycastFilterType.Exclude
    ringOverlap.MaxParts = 128
    table.insert(ringConnections, workspace.DescendantAdded:Connect(trackRingPart))
    table.insert(ringConnections, workspace.DescendantRemoving:Connect(function(part)
        if ringCandidates[part] then
            ringCandidates[part] = nil
            ringCandidateCount = ringCandidateCount - 1
        end
        if ringWatch[part] then ringWatch[part] = nil ringWatchCount = ringWatchCount - 1 end
        removeRingPart(part)
    end))
    local elapsed = 0
    local discoverAt = 0
    table.insert(ringConnections, game:GetService("RunService").Heartbeat:Connect(function(dt)
        local ok, err = pcall(function()
            if not running then stopRing() return end
            elapsed = elapsed + dt
            if elapsed < RING_INTERVAL then return end
            local step = math.min(elapsed, 0.1)
            elapsed = elapsed % RING_INTERVAL -- No catch-up burst after a slow frame.
            local root = getRoot(LocalPlayer)
            if not root then
                for part in pairs(ringParts) do removeRingPart(part) end
                return
            end
            local now = tick()
            for part, movers in pairs(ringParts) do
                if not isRingPart(part) or part.AssemblyRootPart ~= part
                    or (part.Position - root.Position).Magnitude > RING_RELEASE_DISTANCE then
                    removeRingPart(part)
                elseif now >= movers.checkAt then
                    local unsafeAssembly = false
                    for _, connected in ipairs(part:GetConnectedParts(true)) do
                        if not isRingPart(connected) then unsafeAssembly = true break end
                    end
                    local stalled = movers.travelled < 1 and movers.expectedSpeed > 1
                    movers.checkAt = now + 3
                    movers.travelled = 0
                    local owned = ownsRingPart(part)
                    if not owned then ringStats.rejected = ringStats.rejected + 1 end
                    if stalled then ringStats.stalled = ringStats.stalled + 1 end
                    if unsafeAssembly or not owned or stalled then removeRingPart(part, true) end
                end
            end
            if now >= discoverAt then
                discoverAt = now + 0.5
                discoverRingParts(root, now)
            end
            for part, entry in pairs(ringParts) do
                entry.travelled = entry.travelled + (part.Position - entry.lastPosition).Magnitude
                entry.lastPosition = part.Position
                entry.target = getSuperRingTarget(part.Position, root.Position, step)
                local ok, motionError = pcall(function()
                    local velocity = getSuperRingVelocity(part.Position, entry.target, step)
                    entry.expectedSpeed = velocity.Magnitude
                    part.AssemblyLinearVelocity = velocity
                end)
                if not ok then
                    ringLastError = "Debris velocity: " .. tostring(motionError)
                    removeRingPart(part, true)
                end
            end
        end)
        if not ok then
            ringLastError = tostring(err)
            stopRing()
            warn("[Account Manager] Ring stopped:", err)
            replyToHost("Ring stopped after an error. Use ,ringstatus for details.")
        end
    end))
    replyToHost("Ring starting: " .. ringControlStatus .. ". Use ,ringstatus to check debris.")
    -- One initial snapshot per activation, processed in small batches.
    -- Finds loose CanQuery=false parts missed by capped spatial queries.
    task.spawn(function()
        local ok, err = pcall(function()
            if not running or not ringEnabled or ringGeneration ~= generation then return end
            local initial = workspace:GetDescendants()
            for index, part in ipairs(initial) do
                if not running or not ringEnabled or ringGeneration ~= generation then return end
                ringStats.scanned = ringStats.scanned + 1
                trackRingPart(part)
                if index % 128 == 0 then task.wait(RING_INTERVAL) end
            end
        end)
        if not ok and ringGeneration == generation then
            ringLastError = tostring(err)
            warn("[Account Manager] Initial ring discovery failed:", err)
        end
    end)
    task.delay(7, function()
        if running and ringEnabled and ringGeneration == generation then
            replyToHost("Ring: " .. ringCount .. "/" .. ringLimit .. " active; "
                .. ringStats.rejected .. " ownership rejects; " .. ringStats.stalled .. " stalled.")
            if ringCount == 0 then
                replyToHost("No controllable debris yet. Move near loose debris; check ,ringstatus.")
            end
        end
    end)
end)

addCommand({ "ringstatus" }, "Show ring discovery and part-control status.", function()
    replyToHost("Ring " .. (ringEnabled and "ON" or "OFF") .. " | active=" .. ringCount .. "/" .. ringLimit
        .. " | watched=" .. ringWatchCount .. " | scanned=" .. ringStats.scanned)
    replyToHost("Control: " .. ringControlStatus .. " | rejected=" .. ringStats.rejected
        .. " | stalled=" .. ringStats.stalled)
    if ringLastError then replyToHost("Ring error: " .. string.sub(ringLastError, 1, 150)) end
end)

addCommand({ "ringlimit" }, "Set the debris cap. Usage: ,ringlimit <20-150>", function(_, limitArg)
    local limit = tonumber(limitArg)
    if not limit or limit ~= limit or math.abs(limit) == math.huge then
        replyToHost("Usage: ,ringlimit <20-150>")
        return
    end
    ringLimit = math.clamp(math.floor(limit), 20, 150)
    -- Apply a reduced cap immediately, releasing the farthest/smallest debris first.
    local root = getRoot(LocalPlayer)
    local ranked = {}
    for part in pairs(ringParts) do
        table.insert(ranked, {
            part = part,
            score = (root and (part.Position - root.Position).Magnitude or 0)
                - math.min(part.Size.Magnitude, 30) * 0.5,
        })
    end
    table.sort(ranked, function(a, b) return a.score < b.score end)
    for i = ringLimit + 1, #ranked do removeRingPart(ranked[i].part) end
    replyToHost("Ring debris limit: " .. ringLimit)
end)

addCommand({ "unring", "stopring" }, "Stop the super ring and restore debris properties.", function()
    stopRing()
end)

addCommand({ "tp", "goto" }, "Teleport beside a player.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    local targetRoot = target and getRoot(target)
    local root = getRoot(LocalPlayer)
    if root and targetRoot then
        stopBotMovement(LocalPlayer)
        root.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
    end
end)

addCommand({ "spin" }, "Spin in place. Usage: ,spin [speed]", function(_, speedArg)
    local root = getRoot(LocalPlayer)
    if not root then return end
    local speed = math.clamp(tonumber(speedArg) or 18, 1, 100)
    local token = beginBotMode(LocalPlayer, "spin", nil)
    task.spawn(function()
        while isModeActive(LocalPlayer, "spin", token) do
            local currentRoot = getRoot(LocalPlayer)
            if currentRoot then
                currentRoot.CFrame = currentRoot.CFrame * CFrame.Angles(0, math.rad(speed), 0)
            end
            task.wait(0.03)
        end
    end)
end)

addCommand({ "unspin", "stopspin" }, "Stop spinning.", function()
    if getBotState(LocalPlayer).mode == "spin" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "freeze" }, "Freeze the alt in place.", function()
    local root = getRoot(LocalPlayer)
    if not root then return end
    beginBotMode(LocalPlayer, "freeze", nil)
    root.Anchored = true
end)

addCommand({ "unfreeze", "thaw" }, "Unfreeze the alt.", function()
    local root = getRoot(LocalPlayer)
    if root then root.Anchored = false end
    if getBotState(LocalPlayer).mode == "freeze" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "face", "stare" }, "Continuously face a player.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    if not target then return end
    local token = beginBotMode(LocalPlayer, "face", target)
    task.spawn(function()
        while isModeActive(LocalPlayer, "face", token) do
            local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
            if root and targetRoot then
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z))
            end
            task.wait(0.05)
        end
    end)
end)

addCommand({ "unface", "unstare" }, "Stop facing a player.", function()
    if getBotState(LocalPlayer).mode == "face" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "float", "hover" }, "Hover above a player. Usage: ,float [player] [height]", function(_, ...)
    local args = { ... }
    local height = tonumber(args[#args])
    if height then table.remove(args, #args) else height = 8 end
    height = math.clamp(height, 2, 50)
    local target = findPlayer(table.concat(args, " "))
    if not target then target = refreshHost() end
    if not target then replyToHost("Target not found.") return end
    local token = beginBotMode(LocalPlayer, "float", target)
    task.spawn(function()
        while isModeActive(LocalPlayer, "float", token) do
            local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
            if root and targetRoot then
                root.CFrame = CFrame.lookAt(targetRoot.Position + Vector3.new(0, height, 0), targetRoot.Position)
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end
            task.wait(0.05)
        end
    end)
end)

addCommand({ "unfloat", "unhover" }, "Stop hovering.", function()
    if getBotState(LocalPlayer).mode == "float" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "guard", "bodyguard" }, "Guard a player from a tactical rear-right position.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    if not target then return end
    local token = beginBotMode(LocalPlayer, "guard", target)
    startNaturalFollow(LocalPlayer, "guard", target, CFrame.new(3, 0, 3.5), 2.5, token, true)
end)

addCommand({ "guardstyle" }, "Set guard idle style. Usage: ,guardstyle tactical/normal", function(_, styleArg)
    local style = string.lower(tostring(styleArg or ""))
    if style ~= "tactical" and style ~= "normal" then
        replyToHost("Usage: ,guardstyle tactical/normal")
        return
    end
    local state = getBotState(LocalPlayer)
    state.guardStyle = style
    clearGuardPose(LocalPlayer)
    if style == "normal" then
        stopGuardAnimations(LocalPlayer)
    elseif getBotState(LocalPlayer).mode == "guard" then
        loadGuardAnimations(LocalPlayer)
    end
    replyToHost("Guard style set to " .. style .. ".")
end)

addCommand({ "unguard", "stopguard" }, "Stop guarding.", function()
    if getBotState(LocalPlayer).mode == "guard" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "crazyorbit", "spiral" }, "Spiral around a player.", function(_, targetArg, speedArg, radiusArg)
    local target = findPlayer(targetArg or "me")
    if not target then replyToHost("Target not found.") return end
    local speed = math.clamp(tonumber(speedArg) or 24, 1, 100)
    local radius = math.clamp(tonumber(radiusArg) or 7, 2, 30)
    local token = beginBotMode(LocalPlayer, "crazyorbit", target)
    task.spawn(function()
        local angle = 0
        while isModeActive(LocalPlayer, "crazyorbit", token) do
            local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
            if root and targetRoot then
                local wave = math.sin(angle * 2) * 4
                local changingRadius = radius + math.sin(angle * 1.5) * (radius * 0.4)
                local destination = targetRoot.Position + Vector3.new(math.cos(angle) * changingRadius, 4 + wave, math.sin(angle) * changingRadius)
                root.CFrame = CFrame.lookAt(destination, targetRoot.Position)
            end
            angle = angle + math.rad(speed)
            task.wait(0.05)
        end
    end)
end)

addCommand({ "launch", "yeet" }, "Launch the alt upward. Usage: ,launch [power]", function(_, powerArg)
    local root = getRoot(LocalPlayer)
    if root then
        stopBotMovement(LocalPlayer)
        local power = math.clamp(tonumber(powerArg) or 110, 25, 300)
        root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, power, root.AssemblyLinearVelocity.Z)
    end
end)

local savedReturnCFrame = nil
addCommand({ "void" }, "Drop the alt far below the map.", function()
    local root = getRoot(LocalPlayer)
    if root then
        stopBotMovement(LocalPlayer)
        savedReturnCFrame = root.CFrame
        root.CFrame = root.CFrame - Vector3.new(0, 500, 0)
    end
end)

addCommand({ "return", "returnpos" }, "Return from ,void.", function()
    local root = getRoot(LocalPlayer)
    if root and savedReturnCFrame then
        root.CFrame = savedReturnCFrame
        savedReturnCFrame = nil
    end
end)

addCommand({ "clone", "copyavatar" }, "Copy a player's avatar appearance locally.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    local humanoid = getHumanoid(LocalPlayer)
    local targetHumanoid = target and getHumanoid(target)
    if humanoid and targetHumanoid then
        local ok, description = pcall(function() return targetHumanoid:GetAppliedDescription() end)
        if ok and description then
            local applied, err = pcall(function() humanoid:ApplyDescription(description) end)
            if not applied then replyToHost("Avatar copy failed: " .. tostring(err)) end
        end
    end
end)

addCommand({ "copy", "mirror" }, "Mirror a player's movement and jumps.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    if not target then return end
    local token = beginBotMode(LocalPlayer, "copy", target)
    task.spawn(function()
        while isModeActive(LocalPlayer, "copy", token) do
            local humanoid, targetHumanoid = getHumanoid(LocalPlayer), getHumanoid(target)
            if humanoid and targetHumanoid then
                humanoid:Move(targetHumanoid.MoveDirection, false)
                if targetHumanoid.Jump then humanoid.Jump = true end
            end
            task.wait(0.05)
        end
    end)
end)

addCommand({ "uncopy", "unmirror" }, "Stop mirroring.", function()
    if getBotState(LocalPlayer).mode == "copy" then stopBotMovement(LocalPlayer) end
end)

addCommand({ "syncdance" }, "Start a dance on this managed alt.", function(_, dance)
    dance = tostring(dance or "1")
    sendEmote(dance == "1" and "dance" or ("dance" .. dance))
end)

addCommand({ "dramatic" }, "Run a dramatic floating entrance.", function()
    local host = refreshHost()
    local root, hostRoot = getRoot(LocalPlayer), getRoot(host)
    if not root or not hostRoot then return end
    local token = beginBotMode(LocalPlayer, "dramatic", host)
    task.spawn(function()
        root.CFrame = hostRoot.CFrame * CFrame.new(0, 0, 5)
        local started = tick()
        while isModeActive(LocalPlayer, "dramatic", token) and tick() - started < 4 do
            local currentRoot, currentHostRoot = getRoot(LocalPlayer), getRoot(host)
            if currentRoot and currentHostRoot then
                local elapsed = tick() - started
                local height = math.min(elapsed * 2.5, 8)
                local angle = elapsed * 2
                local pos = (currentHostRoot.CFrame * CFrame.new(0, height, 5)).Position
                currentRoot.CFrame = CFrame.new(pos) * CFrame.Angles(0, angle, 0)
                currentRoot.AssemblyLinearVelocity = Vector3.zero
            end
            task.wait(0.03)
        end
        if isModeActive(LocalPlayer, "dramatic", token) then stopBotMovement(LocalPlayer) end
    end)
end)

addCommand({ "players", "playerlist" }, "Print the server player list in the executor console.", function()
    print("=== Account Manager Players (" .. #Players:GetPlayers() .. ") ===")
    for _, player in ipairs(Players:GetPlayers()) do
        print(player.DisplayName .. " | @" .. player.Name .. " | " .. player.UserId)
    end
end)

addCommand({ "server", "serverinfo" }, "Print server information in the executor console.", function()
    print("=== Account Manager Server ===")
    print("PlaceId:", game.PlaceId)
    print("JobId:", game.JobId)
    print("Players:", #Players:GetPlayers() .. "/" .. Players.MaxPlayers)
    print("Uptime:", math.floor(workspace.DistributedGameTime) .. "s")
end)

addCommand({ "undance", "nodance", "nd", "stopdance" }, "Stop the current emote.", function()
    local humanoid = getHumanoid(LocalPlayer)

    if humanoid then
        humanoid.Jump = true
    end
end)

--// Fun movement: shares the normal mode token, so switching modes cancels it.
local function funNumber(value, default, minimum, maximum)
    local number = tonumber(value)
    if not number or number ~= number or math.abs(number) == math.huge then return default end
    return math.clamp(number, minimum, maximum)
end

local function startFunMovement(mode, lockFacing, update)
    local root, humanoid = getRoot(LocalPlayer), getHumanoid(LocalPlayer)
    if not root or not humanoid or humanoid.Health <= 0 then
        replyToHost("Character is not ready.")
        return
    end
    if root.Anchored then
        replyToHost("Use ,unfreeze before starting fun movement.")
        return
    end
    stopBotMovement(LocalPlayer)
    local token = beginBotMode(LocalPlayer, mode, nil)
    local state = getBotState(LocalPlayer)
    state.funHumanoid = humanoid
    state.funAutoRotate = humanoid.AutoRotate
    if lockFacing then humanoid.AutoRotate = false end
    local initial = root.CFrame
    local started = tick()
    task.spawn(function()
        local ok, err = pcall(function()
            while isModeActive(LocalPlayer, mode, token) do
                local currentRoot, currentHumanoid = getRoot(LocalPlayer), getHumanoid(LocalPlayer)
                if currentRoot ~= root or currentHumanoid ~= humanoid
                    or not root.Parent or humanoid.Health <= 0 or root.Anchored then break end
                update(root, humanoid, tick() - started, initial)
                task.wait(0.05)
            end
        end)
        if isModeActive(LocalPlayer, mode, token) then stopBotMovement(LocalPlayer) end
        if not ok then warn("[Account Manager] Fun movement failed:", mode, err) end
    end)
end

addCommand({ "hop", "bunnyhop" }, "Keep hopping. Usage: ,hop [interval 0.4-5]", function(_, intervalArg)
    local interval = funNumber(intervalArg, 1, 0.4, 5)
    local nextHop = 0
    startFunMovement("hop", false, function(_, humanoid, elapsed)
        if elapsed >= nextHop then
            nextHop = elapsed + interval
            humanoid.Jump = true
        end
    end)
end)

addCommand({ "moonwalk" }, "Walk backward while facing forward. Stop with ,stopfun.", function()
    startFunMovement("moonwalk", true, function(root, humanoid, _, initial)
        local backward = Vector3.new(-initial.LookVector.X, 0, -initial.LookVector.Z)
        if backward.Magnitude > 0.001 then humanoid:Move(backward.Unit, false) end
        root.CFrame = CFrame.new(root.Position) * (initial - initial.Position)
    end)
end)

addCommand({ "zigzag" }, "Walk in a zigzag. Usage: ,zigzag [period 0.5-5]", function(_, periodArg)
    local period = funNumber(periodArg, 2, 0.5, 5)
    startFunMovement("zigzag", false, function(_, humanoid, elapsed, initial)
        local direction = initial.LookVector + initial.RightVector * math.sin(elapsed * math.pi * 2 / period)
        direction = Vector3.new(direction.X, 0, direction.Z)
        if direction.Magnitude > 0.001 then humanoid:Move(direction.Unit, false) end
    end)
end)

addCommand({ "wiggle", "shimmy" }, "Wiggle in place. Usage: ,wiggle [degrees 5-60] [speed 0.5-6]", function(_, degreesArg, speedArg)
    local degrees = funNumber(degreesArg, 25, 5, 60)
    local speed = funNumber(speedArg, 2, 0.5, 6)
    startFunMovement("wiggle", true, function(root, _, elapsed, initial)
        root.CFrame = CFrame.new(root.Position) * (initial - initial.Position)
            * CFrame.Angles(0, math.rad(degrees) * math.sin(elapsed * speed * math.pi * 2), 0)
    end)
end)

addCommand({ "sit", "chill" }, "Sit down. Stop with ,unsit or ,stopfun.", function()
    local humanoid = getHumanoid(LocalPlayer)
    if not humanoid or humanoid.Health <= 0 then replyToHost("Character is not ready.") return end
    stopBotMovement(LocalPlayer)
    beginBotMode(LocalPlayer, "sit", nil)
    local state = getBotState(LocalPlayer)
    state.funHumanoid = humanoid
    state.funSitting = true
    humanoid.Sit = true
end)

addCommand({ "unsit", "getup" }, "Stand up from sitting.", function()
    if getBotState(LocalPlayer).mode == "sit" then stopBotMovement(LocalPlayer) end
    local humanoid = getHumanoid(LocalPlayer)
    if humanoid then humanoid.Sit = false end
end)

addCommand({ "stopfun", "unfun" }, "Stop hopping, moonwalking, zigzagging, wiggling, or sitting.", function()
    local mode = getBotState(LocalPlayer).mode
    if mode == "hop" or mode == "moonwalk" or mode == "zigzag" or mode == "wiggle" or mode == "sit" then
        stopBotMovement(LocalPlayer)
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
    if not running then return false end
    if hostChatConnection then
        pcall(function()
            hostChatConnection:Disconnect()
        end)
        hostChatConnection = nil
    end

    if usingTextChatService() then
        hostChatConnection = TextChatService.MessageReceived:Connect(function(chatMessage)
            if not running then return end
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
local playerAddedConnection = Players.PlayerAdded:Connect(function(player)
    if not running then return end
    if player.UserId == HOST_USER_ID then
        Host = player
        print("[Account Manager] Host joined: " .. player.Name)

        if not usingTextChatService() then
            task.defer(function()
                if running then connectHostListener() end
            end)
        end
    end
end)

local playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
    if not running then return end
    if player.UserId == HOST_USER_ID then
        Host = nil
        stopAllMovement()
    end
end)

-- One active instance per executor environment. Older releases have no handle;
-- send ,end to stop those once before loading this release.
shutdownRuntime = function()
    if not running then return end
    running = false
    if hostChatConnection then hostChatConnection:Disconnect() hostChatConnection = nil end
    playerAddedConnection:Disconnect()
    playerRemovingConnection:Disconnect()
    stopAllMovement()
    stopRing()
    if godModeEnabled then commands.ungod() end
    if godConnection then godConnection:Disconnect() godConnection = nil end
    if runtimeEnvironment[RUNTIME_KEY] == runtimeHandle then
        runtimeEnvironment[RUNTIME_KEY] = nil
    end
end

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
    local previousRuntime = runtimeEnvironment[RUNTIME_KEY]
    if type(previousRuntime) == "table" and type(previousRuntime.stop) == "function" then
        local ok, err = pcall(previousRuntime.stop)
        if not ok then warn("[Account Manager] Previous runtime cleanup failed:", err) end
    end
    runtimeHandle = { version = VERSION, stop = shutdownRuntime }
    runtimeEnvironment[RUNTIME_KEY] = runtimeHandle
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
