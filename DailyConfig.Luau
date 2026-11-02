--!strict
--[[
	DailyConfig (shared)
	Daily login rewards (7-day cycle) and the three daily quests. The server reads its own
	copy for amounts, so clients can never choose a reward.
	Days are UTC calendar days: dayIndex = floor(unixSeconds / 86400).
]]
local DailyConfig = {}

DailyConfig.SECONDS_PER_DAY = 86400

-- Coins for streak day 1..7; after day 7 the cycle restarts at day 1.
DailyConfig.LOGIN_REWARDS = { 100, 250, 500, 750, 1250, 2000, 5000 }

export type Quest = { Id: string, Title: string, Description: string, Difficulty: string, Goal: number, Reward: number }
DailyConfig.QUESTS = {
	{ Id = "Plant", Title = "Plant 5 Seeds", Description = "Plant any 5 seeds in your terrarium.", Difficulty = "Easy", Goal = 5, Reward = 150 },
	{ Id = "Harvest", Title = "Harvest 10 Plants", Description = "Harvest 10 fully grown plants of any kind.", Difficulty = "Medium", Goal = 10, Reward = 400 },
	{ Id = "Mutated", Title = "Harvest 2 Mutated Plants", Description = "Harvest 2 Golden, Glowing, Crystal or Rainbow plants.", Difficulty = "Hard", Goal = 2, Reward = 750 },
} :: { Quest }

function DailyConfig.GetQuest(id: any): Quest?
	for _, q in DailyConfig.QUESTS do
		if q.Id == id then
			return q
		end
	end
	return nil
end

function DailyConfig.DayIndex(unixSeconds: number): number
	return unixSeconds // DailyConfig.SECONDS_PER_DAY
end

return table.freeze(DailyConfig)
