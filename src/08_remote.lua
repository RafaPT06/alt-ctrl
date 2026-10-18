--// Remote Control

local REMOTE_SYNC_ENDPOINT = "https://meowz.up.railway.app/api/account-manager/remote/sync"
local REMOTE_SYNC_INTERVAL = 2.5
local remoteActive = false
local remoteLogs = {}
local remoteResults = {}
local remoteSeen = {}

local function remoteRequest()
    return request or http_request
end

local function push(list, value, limit)
    table.insert(list, value)
    while #list > limit do table.remove(list, 1) end
end

local function telemetry()
    local state = getBotState(LocalPlayer)
    local humanoid = getHumanoid(LocalPlayer)
    local effects = {}
    for name in pairs(state.effects or {}) do effects[tostring(name)] = true end
    return {
        altUserId = LocalPlayer.UserId,
        version = VERSION,
        alt = LocalPlayer.Name,
        mode = state.mode or "none",
        target = state.target and state.target.Name or "",
        effects = effects,
        health = humanoid and humanoid.Health or 0,
        placeId = tostring(game.PlaceId),
        jobId = tostring(game.JobId or ""),
        hostPresent = refreshHost() ~= nil,
        logs = remoteLogs,
        results = remoteResults,
    }
end

local function syncRemote()
    local token = tostring(runtimeEnvironment.ACCOUNT_MANAGER_ALT_TOKEN or "")
    local send = remoteRequest()
    if token == "" or type(send) ~= "function" then return false end
    local ok, response = pcall(send, {
        Url = REMOTE_SYNC_ENDPOINT,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json", Authorization = "Bearer " .. token },
        Body = HttpService:JSONEncode(telemetry()),
    })
    if not ok or type(response) ~= "table" then return false end
    local status = tonumber(response.StatusCode or response.Status or 0) or 0
    if status < 200 or status >= 300 then return false end
    local decoded, body = pcall(HttpService.JSONDecode, HttpService, tostring(response.Body or "{}"))
    if not decoded or type(body) ~= "table" or body.ok ~= true then return false end
    remoteLogs, remoteResults = {}, {}
    for _, item in ipairs(type(body.commands) == "table" and body.commands or {}) do
        local id = tonumber(item.id)
        local command = tostring(item.command or "")
        if id and command ~= "" and not remoteSeen[id] then
            remoteSeen[id] = true
            local commandOk, commandError = processCommand(command)
            push(remoteResults, {
                id = id,
                ok = commandOk == true,
                error = commandOk and "" or tostring(commandError or "command_failed"),
                completedAt = os.time(),
            }, 50)
        end
    end
    return true
end

local function startRemoteControl()
    if remoteActive then return end
    if tostring(runtimeEnvironment.ACCOUNT_MANAGER_ALT_TOKEN or "") == "" then
        warn("[Account Manager] Remote control disabled: ACCOUNT_MANAGER_ALT_TOKEN is not set.")
        return
    end
    if type(remoteRequest()) ~= "function" then
        warn("[Account Manager] Remote control disabled: request/http_request is unavailable.")
        return
    end
    remoteActive = true
    task.spawn(function()
        while running and remoteActive do
            local ok, err = pcall(syncRemote)
            if not ok then warn("[Account Manager] Remote sync failed:", err) end
            task.wait(REMOTE_SYNC_INTERVAL)
        end
    end)
end

local function stopRemoteControl()
    remoteActive = false
end

local function getRemoteState()
    return { enabled = remoteActive, queuedResults = #remoteResults, seenCommands = remoteSeen }
end
