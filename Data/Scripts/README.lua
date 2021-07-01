local RUN_TEST = true
if not RUN_TEST then return end



if Environment.IsClient() then
    -- Here we will receive 100 test events from server, to turn them off set
    -- `DEBUG = false` on the top of the "TrustedEventsServer.lua"
    Events.Connect("TE_TEST_EVENT", function(...)
        print("Test Event From Server", ...)
    end)
else -- Server
    while not _G.TEBroadcastToPayer do
        Task.Wait(0.1)
    end
    -- shortcut, to use method without "_G"
    _ENV.TEBroadcastToPayer = _G.TEBroadcastToPayer
    -- ...
    while true do
        for _, player in ipairs(Game.GetPlayers()) do
            TEBroadcastToPayer(player, "TE_TEST_EVENT", "Hello from server!", time()//1)
        end
        Task.Wait(10)
    end
end








