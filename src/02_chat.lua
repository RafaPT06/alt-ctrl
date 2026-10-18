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

        print(
            "[Account Manager] Whisper channel not created yet for",
            HOST_USER_ID,
            LocalPlayer.UserId,
            "- MAIN can send /w " .. LocalPlayer.Name .. " hi once to create it."
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

