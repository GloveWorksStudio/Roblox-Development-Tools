--!strict
--[[
	PlantingService (server only)
	Handles planting requests. The client only says WHERE and WHICH seed; everything else
	(ownership, capacity, placement rules, seed count, distance, rate limiting, mutation) is
	decided here.

	Step 20 - free planting: RequestPlantAt(x, z, species) plants at a terrarium-local spot.
	Planting slots are now capacity tokens: the server takes the lowest free slot and moves it
	to the chosen spot, so growth, harvesting, upgrades and saving keep working per slot.
	The old RequestPlant(slot, species) still works (plants at that slot's current spot).
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlotService = require(ServerScriptService:WaitForChild("PlotSystem"):WaitForChild("PlotService"))
local SeedService = require(script.Parent:WaitForChild("SeedService"))
local GrowthService = require(script.Parent:WaitForChild("GrowthService"))
local MutationService = require(script.Parent:WaitForChild("MutationService"))
local MutationVisuals = require(script.Parent:WaitForChild("MutationVisuals"))
local DataGate = require(ServerScriptService:WaitForChild("Data"):WaitForChild("DataGate"))
local PlantPlacement = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlantPlacement"))
local HttpService = game:GetService("HttpService")

local PlantingService = {}
local plantedEvent = Instance.new("BindableEvent")
-- (player, species, mutation): fired once per SUCCESSFUL, server-validated planting.
PlantingService.Planted = plantedEvent.Event

local REQUEST_COOLDOWN = 0.25 -- seconds between plant requests per player
local MAX_PLANT_DISTANCE = 90 -- studs from character to slot

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Planting")
local RequestPlant = remotes:WaitForChild("RequestPlant") :: RemoteEvent
local RequestPlantAt = remotes:WaitForChild("RequestPlantAt") :: RemoteEvent
local PlantResult = remotes:WaitForChild("PlantResult") :: RemoteEvent
local PlantPlanted = remotes:WaitForChild("PlantPlanted") :: RemoteEvent

local plantModels = ServerStorage:WaitForChild("PlantModels")
local plotsFolder = workspace:WaitForChild("Map"):WaitForChild("Plots")

local lastRequest: { [Player]: number } = {}
local started = false
local rng = Random.new()

local function fail(player: Player, reason: string, slot: Instance?)
	PlantResult:FireClient(player, false, reason, slot)
end

local function getSeedlingTemplate(species: any): Model?
	if typeof(species) ~= "string" or #species > 32 then
		return nil
	end
	local folder = plantModels:FindFirstChild(species)
	local seedling = folder and folder:FindFirstChild("Seedling")
	return if seedling and seedling:IsA("Model") then seedling else nil
end

local function spawnSeedling(template: Model, species: string, slot: BasePart, terrarium: Model, player: Player, mutation: string): Model
	local plant = template:Clone()
	plant.Name = species
	plant:SetAttribute("Species", species)
	plant:SetAttribute("Stage", "Seedling")
	plant:SetAttribute("Mutation", mutation)
	MutationVisuals.Apply(plant, mutation)
	plant:SetAttribute("SlotNumber", slot:GetAttribute("SlotNumber"))
	plant:SetAttribute("OwnerUserId", player.UserId)
	for _, d in plant:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	local point = slot:FindFirstChild("PlantPoint") :: Attachment
	local yaw = slot:GetAttribute("PlantYaw")
	if typeof(yaw) ~= "number" then
		yaw = rng:NextNumber(0, 360)
		slot:SetAttribute("PlantYaw", yaw)
	end
	plant:PivotTo(point.WorldCFrame * CFrame.Angles(0, math.rad(yaw :: number), 0))

	local plantsFolder = terrarium:FindFirstChild("Plants")
	if not plantsFolder then
		plantsFolder = Instance.new("Folder")
		plantsFolder.Name = "Plants"
		plantsFolder.Parent = terrarium
	end
	plant.Parent = plantsFolder

	local ref = slot:FindFirstChild("PlantRef")
	if not ref then
		ref = Instance.new("ObjectValue")
		ref.Name = "PlantRef"
		ref.Parent = slot
	end
	local refValue = ref :: ObjectValue
	refValue.Value = plant
	return plant
end

-- Seeds, mutation, model, growth timer. Nothing here yields, so no other request can interleave.
-- The slot must already be validated and sitting at the planting spot.
local function commitPlant(player: Player, slot: BasePart, species: string, template: Model, terrarium: Model): boolean
	slot:SetAttribute("Occupied", true)
	if not SeedService.Take(player, species, 1) then
		slot:SetAttribute("Occupied", false)
		fail(player, "NoSeeds", slot)
		return false
	end
	if typeof(slot:GetAttribute("PlantId")) ~= "string" then
		slot:SetAttribute("PlantId", HttpService:GenerateGUID(false))
	end

	local mutation = MutationService.Roll(player) -- decided here on the server, never by the client
	local ok, result = pcall(spawnSeedling, template, species, slot, terrarium, player, mutation)
	if not ok then
		-- Roll back so the player loses nothing.
		slot:SetAttribute("Occupied", false)
		slot:SetAttribute("PlantId", nil)
		slot:SetAttribute("PlantYaw", nil)
		SeedService.Give(player, species, 1)
		warn(`[PlantingService] Failed to plant {species} for {player.Name}: {result}`)
		fail(player, "Error", slot)
		return false
	end

	slot:SetAttribute("Species", species)
	GrowthService.StartGrowing(slot, result, species, mutation) -- sets PlantType/PlantedAt/GrowthStage/IsMature and starts the timer
	PlantResult:FireClient(player, true, "Planted", slot)
	plantedEvent:Fire(player, species, mutation)
	PlantPlanted:FireAllClients(result, slot)
	return true
end

-- Shared first checks for both request kinds. Returns the player's terrarium + seedling template.
local function precheck(player: Player, species: any): (Model?, Model?)
	-- Rate limit (also stops rapid double-clicks from doing anything twice).
	local now = os.clock()
	local last = lastRequest[player]
	if last and now - last < REQUEST_COOLDOWN then
		fail(player, "TooFast", nil)
		return nil, nil
	end
	lastRequest[player] = now
	if not DataGate.IsReady(player) then
		fail(player, "DataLoading", nil) -- nothing can change until saved progress has loaded
		return nil, nil
	end
	local template = getSeedlingTemplate(species)
	if not template or not GrowthService.IsKnownSpecies(species) then
		fail(player, "UnknownSeed", nil)
		return nil, nil
	end
	local terrarium = PlotService.GetTerrarium(player) -- always the requesting player's OWN terrarium
	if not terrarium or not terrarium.Parent then
		fail(player, "NoPlot", nil)
		return nil, nil
	end
	if not SeedService.Has(player, species, 1) then
		fail(player, "NoSeeds", nil)
		return nil, nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		fail(player, "NoCharacter", nil)
		return nil, nil
	end
	if (root.Position - terrarium:GetPivot().Position).Magnitude > MAX_PLANT_DISTANCE then
		fail(player, "TooFar", nil)
		return nil, nil
	end
	return terrarium, template
end

-- Free planting: x, z are terrarium-local studs. Every rule is re-checked here.
local function onRequestPlantAt(player: Player, x: any, z: any, species: any)
	local terrarium, template = precheck(player, species)
	if not terrarium or not template then
		return
	end
	local ctx = PlantPlacement.ContextFor(terrarium)
	local ok, reason = PlantPlacement.Check(ctx, species, x, z, nil)
	if not ok then
		fail(player, reason, nil)
		return
	end
	local slot = PlantPlacement.FreeSlot(terrarium)
	if not slot or not slot:FindFirstChild("PlantPoint") then
		fail(player, "Full", nil) -- capacity comes from the terrarium level (6/9/12/16)
		return
	end
	slot.CFrame = PlantPlacement.SlotCFrame(ctx, x, z)
	slot:SetAttribute("PlantYaw", rng:NextNumber(0, 360))
	slot:SetAttribute("PlantId", HttpService:GenerateGUID(false))
	commitPlant(player, slot, species, template, terrarium)
end

local function onRequestPlant(player: Player, slot: any, species: any)
	local terrarium, template = precheck(player, species)
	if not terrarium or not template then
		return
	end

	-- Validate arguments.
	if typeof(slot) ~= "Instance" or not slot:IsA("BasePart") or not slot:FindFirstChild("PlantPoint") then
		fail(player, "InvalidSlot", nil)
		return
	end
	-- Ownership: the slot must be inside THIS player's terrarium.
	local slotsFolder = terrarium:FindFirstChild("PlantingSlots")
	if not slotsFolder or slot.Parent ~= slotsFolder then
		fail(player, if slot:IsDescendantOf(plotsFolder) then "NotYourTerrarium" else "InvalidSlot", slot)
		return
	end

	if slot:GetAttribute("Occupied") == true then
		fail(player, "SlotOccupied", slot)
		return
	end
	-- Free-planting terrariums: the slot's current spot must still obey the placement rules.
	if terrarium:GetAttribute("KitVersion") == 2 then
		local ctx = PlantPlacement.ContextFor(terrarium)
		local l = ctx.pivot:PointToObjectSpace(slot.Position)
		local ok, reason = PlantPlacement.Check(ctx, species, l.X, l.Z, slot)
		if not ok then
			fail(player, reason, slot)
			return
		end
	end
	commitPlant(player, slot, species, template, terrarium)
end

function PlantingService.Start()
	if started then
		return
	end
	started = true
	RequestPlant.OnServerEvent:Connect(onRequestPlant)
	RequestPlantAt.OnServerEvent:Connect(onRequestPlantAt)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return PlantingService
