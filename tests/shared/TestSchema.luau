--[=[
	Shared test schema used by both server and client tests.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)

local schema = PlayerStore.schema
local map = PlayerStore.map
local private = PlayerStore.private

return schema {
	Resources = {
		Cash = 0,
		XP = 0,
	},

	Stats = {
		HighestLevel = 0,
		TotalWins = 0,
	},

	Inventory = map {} :: { [string]: number },
	SelectedSlot = "Default",
	IsVIP = false,

	Settings = private {
		MusicVolume = 0.75,
		ShowTutorial = true,
	},

	Codes = private(map {} :: { [string]: number }),
}
