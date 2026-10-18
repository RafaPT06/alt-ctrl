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

