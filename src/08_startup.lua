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
