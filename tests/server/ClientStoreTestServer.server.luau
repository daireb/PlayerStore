--[=[
	Server-side companion for ClientStore integration tests.
	Loads player data and listens for test signals from the client.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local TestSchema = require(ReplicatedStorage.Tests.Shared.TestSchema)

local TEST_STORE_ID = "PlayerStoreClientTest"

local store = PlayerStore.createServerStore {
	schema = TestSchema,
	storeId = TEST_STORE_ID,
	profileStore = ProfileStore,
}
store:onSessionEnd(function() end) -- disable kick for testing

-- Create a signal remote for the client tests to request changes
local signalRemote = Instance.new("RemoteEvent")
signalRemote.Name = "__PlayerStoreTestSignal"
signalRemote.Parent = ReplicatedStorage

signalRemote.OnServerEvent:Connect(function(player, action: string, value: any)
	local obs = store:observe(player)
	if not obs then
		return
	end

	if action == "setCash" then
		obs:set("Resources/Cash", value)
	elseif action == "setXP" then
		obs:set("Resources/XP", value)
	end
end)

-- Load data for all players
Players.PlayerAdded:Connect(function(player)
	store:loadAsync(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(function()
		store:loadAsync(player)
	end)
end

Players.PlayerRemoving:Connect(function(player)
	store:unloadAsync(player)
end)
