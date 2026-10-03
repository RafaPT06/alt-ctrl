print("=== AM DELTA TEST ===")

local tests = {
    {"task.wait", function() return type(task.wait) end},
    {"table.unpack", function() return type(table.unpack) end},
    {"unpack", function() return type(unpack) end},
    {"Players", function() return game:GetService("Players").LocalPlayer.Name end},
    {"TextChatService", function() return tostring(game:GetService("TextChatService").ChatVersion) end},
    {"GetObjects", function() return type(game.GetObjects) end},
}

for _, test in ipairs(tests) do
    local ok, result = pcall(test[2])
    print(test[1], ok and "OK" or "FAILED", result)
end

print("=== END TEST ===")
