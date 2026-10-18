--// Flex commands

local function resolveTargetFromArgs(...)
    local query = table.concat({ ... }, " ")
    local target = findPlayer(query)
    if not target then
        replyToHost("Target not found.")
    end
    return target
end

addCommand({ "tp", "goto" }, "Teleport beside a player.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    local targetRoot = target and getRoot(target)
    local root = getRoot(LocalPlayer)
    if root and targetRoot then
        root.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
    end
end)

addCommand({ "spin" }, "Spin while other compatible movement continues. Usage: ,spin [speed]", function(_, speedArg)
    local root = getRoot(LocalPlayer)
    if not root then return end
    local speed = math.clamp(tonumber(speedArg) or 18, 1, 100)
    stopEffect(LocalPlayer, "face") -- facing and spinning both control yaw
    local token = startEffect(LocalPlayer, "spin", { speed = speed })
    task.spawn(function()
        while isEffectActive(LocalPlayer, "spin", token) do
            local currentRoot = getRoot(LocalPlayer)
            if currentRoot and not currentRoot.Anchored then
                currentRoot.CFrame = currentRoot.CFrame * CFrame.Angles(0, math.rad(speed), 0)
            end
            task.wait(0.03)
        end
    end)
end)

addCommand({ "unspin", "stopspin" }, "Stop spinning without stopping other movement.", function()
    stopEffect(LocalPlayer, "spin")
end)

addCommand({ "freeze" }, "Freeze the alt in place (pauses positional movement).", function()
    local root = getRoot(LocalPlayer)
    if root then root.Anchored = true end
end)

addCommand({ "unfreeze", "thaw" }, "Unfreeze the alt.", function()
    local root = getRoot(LocalPlayer)
    if root then root.Anchored = false end
end)

addCommand({ "face", "stare" }, "Face a player while compatible movement continues.", function(_, ...)
    local target = resolveTargetFromArgs(...)
    if not target then return end
    stopEffect(LocalPlayer, "spin") -- facing and spinning conflict
    local token = startEffect(LocalPlayer, "face", { target = target })
    task.spawn(function()
        while isEffectActive(LocalPlayer, "face", token) do
            local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
            if root and targetRoot and not root.Anchored then
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z))
            end
            task.wait(0.05)
        end
    end)
end)

addCommand({ "unface", "unstare" }, "Stop facing without stopping other movement.", function()
    stopEffect(LocalPlayer, "face")
end)

addCommand({ "float", "hover" }, "Add a hover height to follow, or hover above a player. Usage: ,float [player] [height]", function(_, ...)
    local args = { ... }
    local height = tonumber(args[#args])
    if height then table.remove(args, #args) else height = 8 end
    height = math.clamp(height, 2, 50)
    local target = findPlayer(table.concat(args, " ")) or refreshHost()
    if not target then replyToHost("Target not found.") return end
    local token = startEffect(LocalPlayer, "float", { target = target, height = height })
    task.spawn(function()
        while isEffectActive(LocalPlayer, "float", token) do
            local state = getBotState(LocalPlayer)
            -- Follow consumes this effect as a vertical offset itself.
            if state.mode ~= "follow" then
                local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
                if root and targetRoot and not root.Anchored then
                    local position = targetRoot.Position + Vector3.new(0, height, 0)
                    root.CFrame = CFrame.new(position) * (root.CFrame - root.CFrame.Position)
                    root.AssemblyLinearVelocity = Vector3.zero
                end
            end
            task.wait(0.05)
        end
    end)
end)

addCommand({ "unfloat", "unhover" }, "Stop hovering without stopping other movement.", function()
    stopEffect(LocalPlayer, "float")
end)






addCommand({ "syncdance" }, "Start a dance on this managed alt.", function(_, dance)
    dance = tostring(dance or "1")
    sendEmote(dance == "1" and "dance" or ("dance" .. dance))
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

addCommand({ "stopfun", "unfun" }, "Stop the current sitting/fun state.", function()
    if getBotState(LocalPlayer).mode == "sit" then
        stopBotMovement(LocalPlayer)
    end
end)

