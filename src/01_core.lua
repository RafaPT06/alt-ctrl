--[[
    Account Manager v3.28.0
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
local VERSION = "3.28.0"
local STAND_ANIMATION_ID = "138791542100078"
local REPORT_ENDPOINT = "https://meowz.up.railway.app/api/account-manager"
local resolvedCatalogAnimations = {}

local function resolveCatalogAnimation(catalogId)
    local key = tostring(catalogId)
    if resolvedCatalogAnimations[key] then return resolvedCatalogAnimations[key] end
    local ok, objects = pcall(function() return game:GetObjects("rbxassetid://" .. key) end)
    if not ok or not objects or not objects[1] then
        warn("[Account Manager] Could not resolve catalog animation:", key)
        return nil
    end
    local root = objects[1]
    local animation = root:IsA("Animation") and root or root:FindFirstChildWhichIsA("Animation", true)
    local resolved = animation and animation.AnimationId or nil
    if resolved and resolved ~= "" then
        if not string.find(resolved, "rbxassetid://", 1, true) then resolved = "rbxassetid://" .. tostring(resolved):gsub("%D", "") end
        resolvedCatalogAnimations[key] = resolved
        print("[Account Manager] Catalog animation " .. key .. " resolved to:", resolved)
    else
        warn("[Account Manager] Catalog item " .. key .. " loaded, but no Animation object was found.")
    end
    pcall(function() root:Destroy() end)
    return resolvedCatalogAnimations[key]
end

local HOST_USER_ID = 3104567111
local ACCOUNTS = { 9039839654 }

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local TeleportService = game:GetService("TeleportService")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local startedAt = tick()
local LocalPlayer = Players.LocalPlayer
local Host = Players:GetPlayerByUserId(HOST_USER_ID)

local function refreshHost()
    Host = Players:GetPlayerByUserId(HOST_USER_ID)
    return Host
end

local function isManagedLocalAccount()
    for _, userId in ipairs(ACCOUNTS) do if LocalPlayer.UserId == userId then return true end end
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
local unpackArgs = table.unpack or unpack
local botStates = {}

local function getCharacter(player)
    if not player then return nil, nil, nil end
    local character = player.Character
    if not character then return nil, nil, nil end
    return character, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function getRoot(player) local _, _, root = getCharacter(player) return root end
local function getHumanoid(player) local _, humanoid = getCharacter(player) return humanoid end

local function findPlayer(query)
    if query == nil or query == "" or string.lower(query) == "me" then return refreshHost() end
    query = string.lower(query)
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.Name) == query or string.lower(player.DisplayName) == query then return player end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if string.find(string.lower(player.Name), query, 1, true) or string.find(string.lower(player.DisplayName), query, 1, true) then return player end
    end
    return nil
end

local function getManagedBots()
    local bots = {}
    for accountIndex, userId in ipairs(ACCOUNTS) do
        if LocalPlayer.UserId == userId then table.insert(bots, { player = LocalPlayer, accountIndex = accountIndex }) break end
    end
    return bots
end

local function getBotState(player)
    local userId = player.UserId
    if not botStates[userId] then
        botStates[userId] = {
            mode = nil, token = 0, target = nil, defaultWalkSpeed = nil,
            standAnimationTrack = nil, savedIdle1 = nil, savedIdle2 = nil,
            savedIdleWeight1 = nil, savedIdleWeight2 = nil, standObjects = nil, effects = {},
            companion = { enabled = false, distance = 6, side = "back", idleLook = true, speedMatch = true },
            horror = { enabled = false, savedWalkSpeed = nil },
        }
    end
    return botStates[userId]
end

local function cleanupStandConstraints(player)
    local state = getBotState(player)
    if state.standObjects then
        for _, object in ipairs(state.standObjects) do if object then pcall(function() object:Destroy() end) end end
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
        if weight and state.savedIdleWeight1 ~= nil then weight.Value = state.savedIdleWeight1 end
    end
    if animation2 and state.savedIdle2 then
        animation2.AnimationId = state.savedIdle2
        local weight = animation2:FindFirstChild("Weight")
        if weight and state.savedIdleWeight2 ~= nil then weight.Value = state.savedIdleWeight2 end
    end
    state.savedIdle1, state.savedIdle2, state.savedIdleWeight1, state.savedIdleWeight2 = nil, nil, nil, nil
    if animate then pcall(function() animate.Disabled = true task.wait() animate.Disabled = false end) end
end

local function cleanupFunMovement(player)
    local state = getBotState(player)
    local humanoid = state.funHumanoid
    if humanoid and humanoid.Parent then
        if state.funAutoRotate ~= nil then humanoid.AutoRotate = state.funAutoRotate end
        if state.funSitting then humanoid.Sit = false end
        humanoid:Move(Vector3.zero)
    end
    state.funHumanoid, state.funAutoRotate, state.funSitting = nil, nil, nil
end

local function getEffectState(player, name)
    local state = getBotState(player) state.effects = state.effects or {} return state.effects[name]
end

local function startEffect(player, name, data)
    local state = getBotState(player) state.effects = state.effects or {}
    local previous = state.effects[name]
    local token = ((previous and previous.token) or 0) + 1
    data = data or {} data.token = token state.effects[name] = data return token
end

local function stopEffect(player, name)
    local state = getBotState(player) state.effects = state.effects or {}
    local effect = state.effects[name]
    if effect then effect.token = (effect.token or 0) + 1 state.effects[name] = nil end
end

local function isEffectActive(player, name, token)
    local effect = getEffectState(player, name) return running and effect ~= nil and effect.token == token
end

local function clearEffects(player)
    local state = getBotState(player) state.effects = state.effects or {}
    for name in pairs(state.effects) do stopEffect(player, name) end
end

local function movementBlocked(player, destination)
    local root = getRoot(player) if not root then return false end
    local delta = destination - root.Position if delta.Magnitude < 3 then return false end
    local params = RaycastParams.new() params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = {}
    for _, other in ipairs(Players:GetPlayers()) do if other.Character then table.insert(excluded, other.Character) end end
    params.FilterDescendantsInstances = excluded
    return workspace:Raycast(root.Position + Vector3.new(0, 1.5, 0), delta.Unit * math.min(delta.Magnitude, 8), params) ~= nil
end

local isModeActive

local function startNaturalFollow(player, mode, target, offset, stopRadius, token)
    task.spawn(function()
        local lastPosition, lastProgressAt, pathWaypoints, pathIndex, pathExpires = nil, tick(), nil, 1, 0
        while isModeActive(player, mode, token) do
            local root, humanoid, targetRoot = getRoot(player), getHumanoid(player), getRoot(target)
            if root and humanoid and targetRoot then
                humanoid.AutoRotate = getEffectState(player, "spin") == nil and getEffectState(player, "face") == nil
                local desired = targetRoot.CFrame * offset
                local floatEffect = getEffectState(player, "float")
                if floatEffect then desired = desired + Vector3.new(0, floatEffect.height or 8, 0) end
                local distance = (root.Position - desired.Position).Magnitude
                if distance > 90 then
                    root.CFrame = desired root.AssemblyLinearVelocity = Vector3.zero root.AssemblyAngularVelocity = Vector3.zero
                    pathWaypoints, lastPosition, lastProgressAt = nil, root.Position, tick()
                elseif distance <= stopRadius then
                    humanoid:Move(Vector3.zero) pathWaypoints = nil
                    if mode == "companion" then
                        local companion = getBotState(player).companion
                        if companion and companion.speedMatch then local th = getHumanoid(target) if th then humanoid.WalkSpeed = th.WalkSpeed end end
                        if companion and companion.idleLook then
                            local lookTarget = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
                            if (lookTarget - root.Position).Magnitude > 0.05 then root.CFrame = CFrame.lookAt(root.Position, lookTarget) end
                        end
                    end
                else
                    if mode == "companion" then
                        local companion = getBotState(player).companion
                        if companion and companion.speedMatch then local th = getHumanoid(target) if th then humanoid.WalkSpeed = th.WalkSpeed end end
                    end
                    local now = tick()
                    if not lastPosition then lastPosition, lastProgressAt = root.Position, now
                    elseif (root.Position - lastPosition).Magnitude >= 1.25 then lastPosition, lastProgressAt = root.Position, now end
                    local stuck, blocked = now - lastProgressAt > 1.0, movementBlocked(player, desired.Position)
                    if (stuck or blocked) and (not pathWaypoints or now >= pathExpires) then
                        local path = PathfindingService:CreatePath({ AgentCanJump = true })
                        local ok = pcall(function() path:ComputeAsync(root.Position, desired.Position) end)
                        if ok and path.Status == Enum.PathStatus.Success then
                            pathWaypoints, pathIndex, pathExpires, lastProgressAt = path:GetWaypoints(), math.min(2, #path:GetWaypoints()), now + 1.5, now
                        else pathWaypoints = nil end
                    end
                    local waypoint = pathWaypoints and pathWaypoints[pathIndex]
                    if waypoint and now < pathExpires then
                        if (root.Position - waypoint.Position).Magnitude < 2.5 then pathIndex = pathIndex + 1 waypoint = pathWaypoints[pathIndex] end
                        if waypoint then
                            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                            humanoid:MoveTo(waypoint.Position)
                        else pathWaypoints = nil humanoid:MoveTo(desired.Position) end
                    else pathWaypoints = nil humanoid:MoveTo(desired.Position) end
                end
            end
            task.wait(0.2)
        end
    end)
end

local function stopBotMovement(player, preserveEffects)
    cleanupFunMovement(player) if not preserveEffects then clearEffects(player) end
    local state = getBotState(player) state.token = state.token + 1 state.mode, state.target = nil, nil
    if state.standAnimationTrack then pcall(function() state.standAnimationTrack:Stop(0.2) state.standAnimationTrack:Destroy() end) state.standAnimationTrack = nil end
    cleanupStandConstraints(player)
    local humanoid = getHumanoid(player) if humanoid then humanoid:Move(Vector3.zero) humanoid.AutoRotate = true end
end

local function stopAllMovement()
    for _, entry in ipairs(getManagedBots()) do stopBotMovement(entry.player) end
end

local function beginBotMode(player, mode, target)
    cleanupFunMovement(player)
    local state = getBotState(player)
    if state.standAnimationTrack then pcall(function() state.standAnimationTrack:Stop(0.2) state.standAnimationTrack:Destroy() end) state.standAnimationTrack = nil end
    cleanupStandConstraints(player)
    state.token = state.token + 1 state.mode, state.target = mode, target
    return state.token
end

isModeActive = function(player, mode, token)
    local state = getBotState(player)
    return running and state.mode == mode and state.token == token
end
