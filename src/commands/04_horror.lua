--// Halloween commands

local function setHorrorMode(enabled)
    local state = getBotState(LocalPlayer)
    state.horror = state.horror or { enabled = false, savedWalkSpeed = nil }
    local humanoid = getHumanoid(LocalPlayer)

    if enabled then
        if humanoid and state.horror.savedWalkSpeed == nil then
            state.horror.savedWalkSpeed = humanoid.WalkSpeed
        end
        state.horror.enabled = true
        if humanoid then humanoid.WalkSpeed = math.min(humanoid.WalkSpeed, 10) end
    else
        state.horror.enabled = false
        if humanoid and state.horror.savedWalkSpeed then
            humanoid.WalkSpeed = state.horror.savedWalkSpeed
        end
        state.horror.savedWalkSpeed = nil
        if state.mode == "stalk" or state.mode == "creep" or state.mode == "scare" then
            stopBotMovement(LocalPlayer, true)
        end
    end
end

addCommand({ "kick", "leave", "disconnect" }, "Disconnect this managed bot from the server.", function()
    LocalPlayer:Kick("Account Manager: disconnected by host.")
end)

addCommand({ "horror", "horrormode" }, "Enable Halloween horror behavior. Use the browser switcher for the horror outfit.", function()
    setHorrorMode(true)
    replyToHost("Horror mode enabled. 🎃")
end)

addCommand({ "unhorror", "normalmode" }, "Disable Halloween horror behavior.", function()
    setHorrorMode(false)
    replyToHost("Horror mode disabled.")
end)

local function targetIsLookingAtBot(target, bot)
    local targetRoot, botRoot = getRoot(target), getRoot(bot)
    if not targetRoot or not botRoot then return false end
    local delta = botRoot.Position - targetRoot.Position
    if delta.Magnitude < 0.1 then return true end
    return targetRoot.CFrame.LookVector:Dot(delta.Unit) > 0.62
end

local function startStalk(bot, target)
    setHorrorMode(true)
    local state = getBotState(bot)
    local token = beginBotMode(bot, "stalk", target)
    task.spawn(function()
        while isModeActive(bot, "stalk", token) do
            local root, humanoid, targetRoot = getRoot(bot), getHumanoid(bot), getRoot(target)
            if root and humanoid and targetRoot then
                humanoid.WalkSpeed = 8
                local desired = targetRoot.CFrame * CFrame.new(0, 0, 12)
                local distance = (root.Position - desired.Position).Magnitude
                if targetIsLookingAtBot(target, bot) then
                    humanoid:Move(Vector3.zero)
                    local look = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
                    if (look - root.Position).Magnitude > 0.1 then root.CFrame = CFrame.lookAt(root.Position, look) end
                elseif distance > 70 then
                    root.CFrame = desired
                    root.AssemblyLinearVelocity = Vector3.zero
                elseif distance > 3 then
                    humanoid:MoveTo(desired.Position)
                else
                    humanoid:Move(Vector3.zero)
                end
            end
            task.wait(0.18)
        end
    end)
end

addCommand({ "stalk" }, "Stalk a player from a distance and freeze when they look at the bot. Usage: ,stalk <player>", function(_, ...)
    local target = findPlayer(table.concat({ ... }, " "))
    if not target then replyToHost("Target not found.") return end
    startStalk(LocalPlayer, target)
end)

addCommand({ "unstalk" }, "Stop stalking.", function()
    if getBotState(LocalPlayer).mode == "stalk" then stopBotMovement(LocalPlayer, true) end
end)

addCommand({ "creep" }, "Slowly approach a player in Horror Mode. Usage: ,creep <player>", function(_, ...)
    local target = findPlayer(table.concat({ ... }, " "))
    if not target then replyToHost("Target not found.") return end
    setHorrorMode(true)
    local token = beginBotMode(LocalPlayer, "creep", target)
    task.spawn(function()
        while isModeActive(LocalPlayer, "creep", token) do
            local root, humanoid, targetRoot = getRoot(LocalPlayer), getHumanoid(LocalPlayer), getRoot(target)
            if root and humanoid and targetRoot then
                humanoid.WalkSpeed = 6
                local desired = targetRoot.CFrame * CFrame.new(0, 0, 4.5)
                if (root.Position - desired.Position).Magnitude > 3 then
                    humanoid:MoveTo(desired.Position)
                else
                    humanoid:Move(Vector3.zero)
                    local look = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
                    if (look - root.Position).Magnitude > 0.1 then root.CFrame = CFrame.lookAt(root.Position, look) end
                end
            end
            task.wait(0.15)
        end
    end)
end)

addCommand({ "scare", "jumpscare" }, "Do a short harmless scare near a player. Usage: ,scare <player>", function(_, ...)
    local target = findPlayer(table.concat({ ... }, " "))
    if not target then replyToHost("Target not found.") return end
    setHorrorMode(true)
    local token = beginBotMode(LocalPlayer, "scare", target)
    task.spawn(function()
        local root, targetRoot = getRoot(LocalPlayer), getRoot(target)
        if root and targetRoot and isModeActive(LocalPlayer, "scare", token) then
            root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 7)
            root.AssemblyLinearVelocity = Vector3.zero
            local look = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
            root.CFrame = CFrame.lookAt(root.Position, look)
            task.wait(0.65)
            if isModeActive(LocalPlayer, "scare", token) then
                root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 3.25)
                root.AssemblyLinearVelocity = Vector3.zero
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z))
                task.wait(1.1)
            end
        end
        if isModeActive(LocalPlayer, "scare", token) then stopBotMovement(LocalPlayer, true) end
    end)
end)

addCommand({ "unscare", "stopscare", "uncreep" }, "Stop the active creep/scare behavior.", function()
    local mode = getBotState(LocalPlayer).mode
    if mode == "scare" or mode == "creep" then stopBotMovement(LocalPlayer, true) end
end)

