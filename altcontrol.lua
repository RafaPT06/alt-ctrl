--[[
    Account Manager modular loader

    The implementation lives under /src and is downloaded as separate files.
    The files are concatenated before execution so the existing lexical scope is shared.
]]

local environment = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then environment = value end
end

local SOURCE_REF = tostring(environment.ACCOUNT_MANAGER_SOURCE_REF or "main")
local BASE_URL = "https://raw.githubusercontent.com/RafaPT06/alt-ctrl/" .. SOURCE_REF .. "/"

local SOURCE_FILES = {
    "src/01_core.lua",
    "src/02_chat.lua",
    "src/commands/01_general.lua",
    "src/commands/02_emotes_player.lua",
    "src/commands/03_movement.lua",
    "src/commands/04_horror.lua",
    "src/commands/05_flex_fun.lua",
    "src/06_dispatcher.lua",
    "src/07_host_listener.lua",
    "src/08_remote.lua",
    "src/08_startup.lua",
}

local chunks = {}
for index, path in ipairs(SOURCE_FILES) do
    local ok, source = pcall(function()
        return game:HttpGet(BASE_URL .. path)
    end)
    if not ok or type(source) ~= "string" or source == "" then
        error("[Account Manager] Failed to load module " .. path .. ": " .. tostring(source))
    end
    chunks[index] = source
end

local source = table.concat(chunks, "\n")
local compiled, compileError = loadstring(source, "AccountManager@" .. SOURCE_REF)
if not compiled then
    error("[Account Manager] Modular source failed to compile: " .. tostring(compileError))
end

return compiled()
