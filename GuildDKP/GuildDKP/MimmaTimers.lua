--[[
	Author:			Mimma
	Create Date:	9/04/2015 13:04:10
]]


--[[
	Timers:
	Timer structure: { Function, TimestampEnd }
]]
local mimmaTimers = {}
local mimmaTimerTick = 0


function OnMimmaTimer(self, elapsed)
	mimmaTimerTick = mimmaTimerTick + elapsed

	for n=1,table.getn(mimmaTimers),1 do
		local timer = mimmaTimers[n]
		if mimmaTimerTick > timer[2] then
			mimmaTimers[n] = nil
			timer[1]()
		end
	end
end

function AddMimmaTimer( method, duration )
	mimmaTimers[table.getn(mimmaTimers) + 1] = { method, mimmaTimerTick + duration }
end

