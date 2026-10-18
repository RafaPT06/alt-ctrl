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

shutdownRuntime = function()
    if not running then return end
    running = false

    if type(stopRemoteControl) == "function" then
        pcall(stopRemoteControl)
    end

    if hostChatConnection then
        hostChatConnection:Disconnect()
        hostChatConnection = nil
    end

    playerAddedConnection:Disconnect()
    playerRemovingConnection:Disconnect()
    stopAllMovement()

    if runtimeEnvironment[RUNTIME_KEY] == runtimeHandle then
        runtimeEnvironment[RUNTIME_KEY] = nil
    end
end
