--!strict
--[[
	CoinService (server only)
	The single source of truth for coin balances. Balances live in a server table;
	leaderstats.Coins is a read-only mirror for the leaderboard and the coin UI.
	Nothing a client sends can change a balance: only server code calls Add/Spend.
	Not saved yet (DataStore saving comes in a later step).
]]
local Players = game:GetService("Players")

local CoinService = {}

local STARTING_COINS = 0

local balances: { [Player]: number } = {}
local mirrors: { [Player]: IntValue } = {}
local started = false

local function sync(player: Player)
	local value = mirrors[player]
	if value then
		value.Value = balances[player] or 0
	end
end

function CoinService.Get(player: Player): number
	return balances[player] or 0
end

-- Adds a positive, whole number of coins. Returns the new balance (or nil if invalid).
function CoinService.Add(player: Player, amount: number): number?
	if balances[player] == nil or typeof(amount) ~= "number" or amount <= 0 or amount ~= math.floor(amount) then
		return nil
	end
	balances[player] += amount
	sync(player)
	return balances[player]
end

-- Removes coins only if the player can afford it. (For future shops.)
function CoinService.Spend(player: Player, amount: number): boolean
	local bal = balances[player]
	if bal == nil or typeof(amount) ~= "number" or amount <= 0 or amount ~= math.floor(amount) or bal < amount then
		return false
	end
	balances[player] = bal - amount
	sync(player)
	return true
end

-- Sets the balance outright. Only the server's data loader uses this.
function CoinService.Set(player: Player, amount: number)
	if balances[player] == nil or typeof(amount) ~= "number" or amount ~= amount or amount < 0 then
		return
	end
	balances[player] = math.floor(amount)
	sync(player)
end

local function onPlayerAdded(player: Player)
	if balances[player] ~= nil then
		return
	end
	balances[player] = STARTING_COINS

	local leaderstats = player:FindFirstChild("leaderstats") or Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = STARTING_COINS
	coins.Parent = leaderstats
	leaderstats.Parent = player
	mirrors[player] = coins
end

function CoinService.Start()
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		balances[player] = nil
		mirrors[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return CoinService
