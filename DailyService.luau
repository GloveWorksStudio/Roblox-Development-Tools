--!strict
--[[
	DailyService (server only)
	Daily login rewards + daily quests, using SERVER UTC time only (os.time()).

	Login: one manual claim per UTC day. Claiming the day after your last claim advances
	the streak; missing a whole UTC day restarts at Day 1; after Day 7 it cycles to Day 1.
	Quests: progress comes only from server events (PlantingService.Planted /
	HarvestService.Harvested), which fire once per successful, validated action in the
	player's own terrarium. Progress resets when the UTC day changes.

	Claims: checked here, then the claimed flag + coins change in ONE synchronous step
	(no yields), and listeners (DataService) write both into the save record together.
	State is mirrored to the player attribute "Daily" (JSON) for the UI.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local DailyConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DailyConfig"))
local CoinService = require(ServerScriptService:WaitForChild("Economy"):WaitForChild("CoinService"))
local DataGate = require(ServerScriptService:WaitForChild("Data"):WaitForChild("DataGate"))
local PlantingService = require(ServerScriptService:WaitForChild("PlantingSystem"):WaitForChild("PlantingService"))
local HarvestService = require(ServerScriptService:WaitForChild("PlantingSystem"):WaitForChild("HarvestService"))

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Daily")
local ClaimLogin = remotes:WaitForChild("ClaimLogin") :: RemoteFunction
local ClaimQuest = remotes:WaitForChild("ClaimQuest") :: RemoteFunction
local Refresh = remotes:WaitForChild("Refresh") :: RemoteFunction

local DAY = DailyConfig.SECONDS_PER_DAY
local CYCLE = #DailyConfig.LOGIN_REWARDS

local DailyService = {}

type Login = { LastClaimDay: number, Streak: number, LastRewardDay: number }
type Quests = { Day: number, Progress: { [string]: number }, Claimed: { [string]: boolean } }
type State = { Login: Login, Quests: Quests }

local states: { [Player]: State } = {}
local listeners: { (Player, any, string) -> () } = {}
local lastRequest: { [Player]: number } = {}
local started = false

-- Studio-only test offset (seconds). Always 0 on live servers: nothing outside Studio
-- can change it, and the real server clock is never modified.
local clockOffset = 0

local function now(): number
	return os.time() + clockOffset
end
local function today(): number
	return DailyConfig.DayIndex(now())
end

local function freshQuests(day: number): Quests
	local progress, claimed = {}, {}
	for _, q in DailyConfig.QUESTS do
		progress[q.Id] = 0
		claimed[q.Id] = false
	end
	return { Day = day, Progress = progress, Claimed = claimed }
end

-- Lazily start a new quest day when the UTC date changed.
local function rollover(state: State): boolean
	local d = today()
	if state.Quests.Day ~= d then
		state.Quests = freshQuests(d)
		return true
	end
	return false
end

-- What the login calendar should show right now.
local function loginStatus(state: State)
	local d = today()
	local login = state.Login
	local claimedToday = login.LastClaimDay == d
	local continuing = login.LastClaimDay == d - 1
	local day
	if claimedToday then
		day = login.LastRewardDay -- the day already claimed today
	elseif continuing then
		day = login.LastRewardDay % CYCLE + 1 -- next day of the streak (7 -> 1)
	else
		day = 1 -- first claim, or a missed UTC day: streak restarts
	end
	return claimedToday, day, continuing
end

local function saveable(state: State)
	return {
		Login = table.clone(state.Login),
		Quests = { Day = state.Quests.Day, Progress = table.clone(state.Quests.Progress), Claimed = table.clone(state.Quests.Claimed) },
	}
end

-- Mirrors state to the client and (synchronously) to listeners. reason "Claim" asks
-- DataService to also capture coins and save right away.
local function publish(player: Player, state: State, reason: string)
	local claimedToday, day = loginStatus(state)
	local quests = {}
	for _, q in DailyConfig.QUESTS do
		table.insert(quests, { id = q.Id, progress = state.Quests.Progress[q.Id] or 0, claimed = state.Quests.Claimed[q.Id] == true })
	end
	player:SetAttribute("Daily", HttpService:JSONEncode({
		now = now(),
		offset = clockOffset,
		resetAt = (today() + 1) * DAY, -- next 00:00 UTC (authoritative)
		-- streak shown = consecutive claimed days still alive (0 once a UTC day was missed)
		login = { claimedToday = claimedToday, day = day, streak = if claimedToday or state.Login.LastClaimDay == today() - 1 then state.Login.Streak else 0 },
		quests = quests,
	}))
	local data = saveable(state)
	for _, fn in listeners do
		fn(player, data, reason) -- synchronous on purpose (see header)
	end
end

local function throttle(player: Player, seconds: number): boolean
	local t = os.clock()
	if lastRequest[player] and t - lastRequest[player] < seconds then
		return false
	end
	lastRequest[player] = t
	return true
end

---------------------------------------------------------------- claims
local function onClaimLogin(player: Player)
	if not throttle(player, 0.3) then
		return { ok = false, reason = "TooFast" }
	end
	local state = states[player]
	if not state or not DataGate.IsReady(player) then
		return { ok = false, reason = "DataLoading" }
	end
	local claimedToday, day, continuing = loginStatus(state)
	if claimedToday then
		return { ok = false, reason = "AlreadyClaimed" }
	end
	local reward = DailyConfig.LOGIN_REWARDS[day]
	-- One synchronous update: claimed status + coins (nothing here yields).
	state.Login.LastClaimDay = today()
	state.Login.LastRewardDay = day
	state.Login.Streak = if continuing then state.Login.Streak + 1 else 1
	CoinService.Add(player, reward)
	publish(player, state, "Claim")
	return { ok = true, reason = "Claimed", day = day, reward = reward }
end

local function onClaimQuest(player: Player, questId: any)
	if not throttle(player, 0.3) then
		return { ok = false, reason = "TooFast" }
	end
	local state = states[player]
	if not state or not DataGate.IsReady(player) then
		return { ok = false, reason = "DataLoading" }
	end
	local quest = DailyConfig.GetQuest(questId)
	if not quest then
		return { ok = false, reason = "Invalid" }
	end
	if rollover(state) then
		publish(player, state, "Rollover")
	end
	if state.Quests.Claimed[quest.Id] then
		return { ok = false, reason = "AlreadyClaimed" }
	end
	if (state.Quests.Progress[quest.Id] or 0) < quest.Goal then
		return { ok = false, reason = "NotComplete" }
	end
	state.Quests.Claimed[quest.Id] = true
	CoinService.Add(player, quest.Reward)
	publish(player, state, "Claim")
	return { ok = true, reason = "Claimed", reward = quest.Reward }
end

local function onRefresh(player: Player)
	-- The client asks once when its countdown reaches 0 (server also refreshes everyone).
	if not throttle(player, 1) then
		return false
	end
	local state = states[player]
	if state then
		rollover(state)
		publish(player, state, "Refresh")
	end
	return true
end

---------------------------------------------------------------- quest progress
local function addProgress(player: Player, questId: string, amount: number)
	local state = states[player]
	if not state or not DataGate.IsReady(player) then
		return
	end
	rollover(state)
	local quest = DailyConfig.GetQuest(questId)
	if not quest then
		return
	end
	local current = state.Quests.Progress[questId] or 0
	if current >= quest.Goal then
		return -- already complete; nothing to change (no extra traffic)
	end
	state.Quests.Progress[questId] = math.min(quest.Goal, current + amount)
	publish(player, state, "Progress")
end

---------------------------------------------------------------- midnight refresh (one timer for the server)
local scheduleToken = 0
local function refreshAll()
	for player, state in states do
		rollover(state)
		publish(player, state, "Rollover")
	end
end
local function scheduleMidnight()
	scheduleToken += 1
	local token = scheduleToken
	local wait = (today() + 1) * DAY - now() + 1
	task.delay(wait, function()
		if token == scheduleToken then
			refreshAll()
			scheduleMidnight()
		end
	end)
end

---------------------------------------------------------------- public
-- Called by DataService with the validated saved data (nil clears the player).
function DailyService.SetForPlayer(player: Player, saved: any)
	if saved == nil then
		states[player] = nil
		player:SetAttribute("Daily", nil)
		return
	end
	local q = saved.Quests or {}
	local state: State = {
		Login = { LastClaimDay = saved.Login.LastClaimDay, Streak = saved.Login.Streak, LastRewardDay = saved.Login.LastRewardDay },
		Quests = freshQuests(q.Day or today()),
	}
	for _, quest in DailyConfig.QUESTS do
		state.Quests.Progress[quest.Id] = (q.Progress or {})[quest.Id] or 0
		state.Quests.Claimed[quest.Id] = (q.Claimed or {})[quest.Id] == true
	end
	states[player] = state
	rollover(state) -- a new UTC day since the last session: fresh quests
	publish(player, state, "Load")
end

-- fn(player, saveableData, reason) - called synchronously on every change.
function DailyService.OnChanged(fn: (Player, any, string) -> ())
	table.insert(listeners, fn)
end

function DailyService.Start()
	if started then
		return
	end
	started = true
	ClaimLogin.OnServerInvoke = onClaimLogin
	ClaimQuest.OnServerInvoke = onClaimQuest
	Refresh.OnServerInvoke = onRefresh
	PlantingService.Planted:Connect(function(player: Player)
		addProgress(player, "Plant", 1)
	end)
	HarvestService.Harvested:Connect(function(player: Player, _plantType, mutationName: string)
		addProgress(player, "Harvest", 1)
		if mutationName ~= nil and mutationName ~= "Normal" then
			addProgress(player, "Mutated", 1)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		lastRequest[player] = nil
	end)
	scheduleMidnight()

	if RunService:IsStudio() then
		-- Developer-only (Studio): simulate other UTC dates and quest progress.
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "_DailyTestBridge"
		bridge.OnInvoke = function(command: string, a: any, b: any, c: any)
			if command == "AdvanceDays" then
				clockOffset += (a :: number) * DAY
				scheduleMidnight()
				refreshAll()
				return today()
			elseif command == "SetOffset" then
				clockOffset = a
				scheduleMidnight()
				refreshAll()
				return today()
			elseif command == "Today" then
				return today(), now()
			elseif command == "SetProgress" then
				local state = states[a]
				if state then
					rollover(state)
					state.Quests.Progress[b] = c
					publish(a, state, "Progress")
				end
				return true
			elseif command == "State" then
				return states[a] and saveable(states[a])
			end
			return nil
		end
		bridge.Parent = game:GetService("ServerStorage")
	end
end

return DailyService
