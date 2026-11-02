--!strict
--[[
	HarvestService (server only)
	Handles "harvest the plant in this slot" requests. The client only names the
	slot; ownership, plant type, maturity, the reward amount and the coin payout are
	all decided here. Each harvest is done in one uninterrupted step (no yields), so
	a plant can only ever be paid out once, however fast requests arrive.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlotService = require(ServerScriptService:WaitForChild("PlotSystem"):WaitForChild("PlotService"))
local CoinService = require(ServerScriptService:WaitForChild("Economy"):WaitForChild("CoinService"))
local MutationConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MutationConfig"))
local DataGate = require(ServerScriptService:WaitForChild("Data"):WaitForChild("DataGate"))
local GrowthService = require(ServerScriptService:WaitForChild("PlantingSystem"):WaitForChild("GrowthService"))

local HarvestService = {}
local harvestedEvent = Instance.new("BindableEvent")
-- (player, plantType, mutationName, reward): fired once per SUCCESSFUL harvest.
HarvestService.Harvested = harvestedEvent.Event

local REQUEST_COOLDOWN = 0.2 -- seconds between harvest requests per player
local MAX_HARVEST_DISTANCE = 90 -- studs from character to slot

-- Coins paid per harvested plant (server-side only; never sent by clients).
local PlantConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlantConfig"))
local HARVEST_REWARDS: { [string]: number } = {}
for _, p in PlantConfig.List() do
	HARVEST_REWARDS[p.Id] = p.BaseReward
end

-- Every attribute the planting/growth systems put on a slot for its plant.
local PLANT_ATTRIBUTES = { "PlantType", "Species", "PlantedAt", "GrowthDuration", "GrowthStage", "IsMature", "OfflineCredited", "Mutation", "WeatherBonus", "BonusSince", "EcoAwarded", "PlantId", "PlantYaw" }

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Harvesting")
local RequestHarvest = remotes:WaitForChild("RequestHarvest") :: RemoteEvent
local HarvestResult = remotes:WaitForChild("HarvestResult") :: RemoteEvent
local PlantHarvested = remotes:WaitForChild("PlantHarvested") :: RemoteEvent

local plotsFolder = workspace:WaitForChild("Map"):WaitForChild("Plots")
local lastRequest: { [Player]: number } = {}
local started = false

local function fail(player: Player, reason: string, slot: Instance?)
	HarvestResult:FireClient(player, false, reason, slot)
end

local Debris = game:GetService("Debris")
local HARVEST_ANIMATION_SECONDS = 1.2 -- the picked plant lingers (cosmetic only) so every client can animate it

-- Removes the plant model(s) and all plant data from a slot, leaving it plantable.
-- Returns the picked plant model: it is already out of the Plants folder (no system counts it)
-- and is destroyed automatically after a moment, so clients can play the collect animation.
local function clearSlot(slot: BasePart, terrarium: Model): Model?
	local slotNumber = slot:GetAttribute("SlotNumber")
	local picked: Model? = nil
	local ref = slot:FindFirstChild("PlantRef")
	if ref and ref:IsA("ObjectValue") then
		local model = ref.Value
		if model and model:IsA("Model") then
			local folder = terrarium:FindFirstChild("Harvesting")
			if not folder then
				folder = Instance.new("Folder")
				folder.Name = "Harvesting"
				folder.Parent = terrarium
			end
			model:SetAttribute("SlotNumber", nil) -- no longer belongs to any slot
			model:SetAttribute("Harvested", true)
			model.Parent = folder
			Debris:AddItem(model, HARVEST_ANIMATION_SECONDS)
			picked = model
		elseif model then
			model:Destroy()
		end
		ref:Destroy()
	end
	local plants = terrarium:FindFirstChild("Plants")
	if plants then
		for _, plant in plants:GetChildren() do
			if plant:GetAttribute("SlotNumber") == slotNumber then
				plant:Destroy() -- safety net: no leftover models for this slot
			end
		end
	end
	for _, name in PLANT_ATTRIBUTES do
		slot:SetAttribute(name, nil)
	end
	slot:SetAttribute("Occupied", false)
	return picked
end

local function onRequestHarvest(player: Player, slot: any)
	-- Note: any extra arguments a client sends (e.g. a coin amount) are ignored.
	local now = os.clock()
	local last = lastRequest[player]
	if last and now - last < REQUEST_COOLDOWN then
		fail(player, "TooFast", nil)
		return
	end
	lastRequest[player] = now

	if not DataGate.IsReady(player) then
		fail(player, "DataLoading", nil) -- nothing can change until saved progress has loaded
		return
	end
	if typeof(slot) ~= "Instance" or not slot:IsA("BasePart") or not slot:FindFirstChild("PlantPoint") then
		fail(player, "InvalidSlot", nil)
		return
	end

	-- 1. Ownership
	local terrarium = PlotService.GetTerrarium(player)
	if not terrarium or not terrarium.Parent then
		fail(player, "NoPlot", slot)
		return
	end
	local slotsFolder = terrarium:FindFirstChild("PlantingSlots")
	if not slotsFolder or slot.Parent ~= slotsFolder then
		fail(player, if slot:IsDescendantOf(plotsFolder) then "NotYourTerrarium" else "InvalidSlot", slot)
		return
	end

	-- 2. There is a known plant here
	local plantType = slot:GetAttribute("PlantType")
	if slot:GetAttribute("Occupied") ~= true or typeof(plantType) ~= "string" then
		fail(player, "Empty", slot)
		return
	end
	local reward = HARVEST_REWARDS[plantType]
	if not reward then
		fail(player, "CannotHarvest", slot)
		return
	end

	-- 3. Fully mature: the growth system's flag AND the server clock must both agree
	local plantedAt = slot:GetAttribute("PlantedAt")
	local duration = slot:GetAttribute("GrowthDuration")
	if slot:GetAttribute("IsMature") ~= true
		or typeof(plantedAt) ~= "number"
		or typeof(duration) ~= "number"
		or GrowthService.GetGrowth(slot) < duration -- weather-aware growth, server-calculated
	then
		fail(player, "NotReady", slot)
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		fail(player, "NoCharacter", slot)
		return
	end
	if (root.Position - slot.Position).Magnitude > MAX_HARVEST_DISTANCE then
		fail(player, "TooFar", slot)
		return
	end

	-- Mutation multiplier, read from the server-set slot data (unknown/missing = Normal).
	local mutationName = slot:GetAttribute("Mutation")
	local mutation = MutationConfig.Get(mutationName) or MutationConfig.Get(MutationConfig.DEFAULT)
	mutationName = (mutation :: any).Name
	reward *= (mutation :: any).Multiplier

	-- 4-7. Commit atomically (nothing below yields): clear the slot first, then pay.
	local effectPosition = slot.PlantPoint.WorldPosition
	local harvestedType = slot:GetAttribute("PlantType")
	local picked = clearSlot(slot, terrarium)
	local newBalance = CoinService.Add(player, reward)
	harvestedEvent:Fire(player, harvestedType, mutationName, reward)

	HarvestResult:FireClient(player, true, "Harvested", slot, reward, newBalance)
	-- one event for everyone nearby; the picked model rides along so each client animates it locally
	PlantHarvested:FireAllClients(effectPosition, reward, player.UserId, mutationName, picked)
end

function HarvestService.Start()
	if started then
		return
	end
	started = true
	RequestHarvest.OnServerEvent:Connect(onRequestHarvest)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return HarvestService
