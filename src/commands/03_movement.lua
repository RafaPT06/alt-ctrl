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
        if state.mode == "follow" or state.mode == "stand" then stopBotMovement(entry.player, true) end
    end
end)

local function companionOffset(side, distance)
    if side == "front" then return CFrame.new(0, 0, -distance) end
    if side == "left" then return CFrame.new(-distance, 0, 0) end
    if side == "right" then return CFrame.new(distance, 0, 0) end
    return CFrame.new(0, 0, distance)
end

local function startCompanion(bot)
    local host = refreshHost()
    if not host then replyToHost("Host not found.") return end
    local state = getBotState(bot)
    state.companion = state.companion or { distance = 6, side = "back", idleLook = true, speedMatch = true }
    state.companion.enabled = true
    local token = beginBotMode(bot, "companion", host)
    startNaturalFollow(bot, "companion", host, companionOffset(state.companion.side, state.companion.distance), 2.75, token)
end

addCommand({ "companion", "buddy" }, "Persistent companion mode. Usage: ,companion [distance N | side back/front/left/right | idle on/off | speedmatch on/off]", function(_, ...)
    local args = { ... }
    local sub = string.lower(tostring(args[1] or ""))
    local value = string.lower(tostring(args[2] or ""))
    local bots = getManagedBots()
    if #bots == 0 then replyToHost("No managed accounts available.") return end

    for _, entry in ipairs(bots) do
        local bot = entry.player
        local state = getBotState(bot)
        state.companion = state.companion or { distance = 6, side = "back", idleLook = true, speedMatch = true }
        local config = state.companion

        if sub == "distance" then
            local distance = tonumber(args[2])
            if not distance then replyToHost("Usage: ,companion distance <2-30>") return end
            config.distance = math.clamp(distance, 2, 30)
        elseif sub == "side" then
            if value ~= "back" and value ~= "front" and value ~= "left" and value ~= "right" then
                replyToHost("Side must be back, front, left, or right.") return
            end
            config.side = value
        elseif sub == "idle" then
            if value ~= "on" and value ~= "off" then replyToHost("Usage: ,companion idle <on/off>") return end
            config.idleLook = value == "on"
        elseif sub == "speedmatch" then
            if value ~= "on" and value ~= "off" then replyToHost("Usage: ,companion speedmatch <on/off>") return end
            config.speedMatch = value == "on"
        elseif sub ~= "" and sub ~= "on" then
            replyToHost("Usage: ,companion [distance N | side back/front/left/right | idle on/off | speedmatch on/off]")
            return
        end

        startCompanion(bot)
    end
end)

addCommand({ "uncompanion", "unbuddy" }, "Disable persistent companion mode.", function()
    for _, entry in ipairs(getManagedBots()) do
        local state = getBotState(entry.player)
        if state.companion then state.companion.enabled = false end
        if state.mode == "companion" then stopBotMovement(entry.player, true) end
    end
end)

