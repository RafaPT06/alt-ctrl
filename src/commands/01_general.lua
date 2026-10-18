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

addCommand({ "help", "cmds", "commands" }, "Send the complete command list to Discord.", function()
    local names = {}
    local entries = {}

    for name in pairs(commandInfo) do
        table.insert(names, name)
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local info = commandInfo[name]
        table.insert(entries, {
            command = PREFIX .. name,
            aliases = info.aliases,
            description = info.description,
        })
    end

    local sent = reportToDiscord("help", { commands = entries })
    if not sent then
        warn("[Account Manager] Could not send help to Discord.")
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
            stopBotMovement(entry.player, true)
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


addCommand({ "end", "stop", "quit", "exit", "close" }, "Disable Account Manager commands.", function()
    if shutdownRuntime then shutdownRuntime() end
    replyToHost("Account Manager successfully closed.")
end)

