--[[
	DataGate
	"Is this player's saved data loaded?" Planting, harvesting and buying all refuse
	until it is, so nothing can happen to a session that might not be the real one.
]]
local Players = game:GetService("Players")

local DataGate = {}
local ready: { [Player]: boolean } = {}

function DataGate.SetReady(player: Player, isReady: boolean)
	ready[player] = if isReady then true else nil
end

function DataGate.IsReady(player: Player): boolean
	return ready[player] == true
end

Players.PlayerRemoving:Connect(function(player)
	ready[player] = nil
end)

return DataGate
