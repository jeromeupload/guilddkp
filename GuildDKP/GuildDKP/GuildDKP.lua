--[[
	Author:			Mimma
	Create Date:	9/21/2012 6:25:10 PM
	
	Dependencies:
	* MimmaTimers.lua
]]

--  Default values for vars stored in SavedVariables:
GDKP_DebugLevel = 0
GDKP_DkpStringLength = 0


-- Use Officer notes (true) or Public notes (false)
local useOfficerNotes = true
-- Max number of players shown in /gdclass output; used to stop spam when displaying guild top X
local maxClassMembersShown = 10

local RAID_CHANNEL = "RAID"
local WARN_CHANNEL = "RAID_WARNING"
local GUILD_CHANNEL = "GUILD"
local OFFICER_CHANNEL = "OFFICER"
local CHAT_END = "|r"
local COLOUR_CHAT = "|c8040A0F8"
local COLOUR_INTRO  = "|c8000F0F0"
local GUILDDKP_PREFIX = "GuildDKPv1"

--	These colours are only used local; don't want to risk a ban :-)
local COLOUR_DKP_MINUS = "|c80FF3030"
local COLOUR_DKP_PLUS = "|c8010FF10"

--	# of transactions displayed in /gdlog
local TRANSACTION_LIST_SIZE = 5
--	# of player names displayed per line when posting transaction log into guild chat
local TRANSACTION_PLAYERS_PER_LINE = 8

local TRANSACTION_STATE_ROLLEDBACK = 0
local TRANSACTION_STATE_ACTIVE = 1

local GuildDKPFrame = CreateFrame("Frame")

-- true if a job is already running
local jobRunning = false
--	List of {jobname,name,dkp} tables
local jobQueue = {}
--	List of {name,dkp,class,online} tables for players in the raid
local raidRoster = {}
--	List of {name,dkp,class} tables for players in the guild
local guildRoster = {}
--	List of valid class names
local classNames = { "Druid", "Hunter", "Mage", "Warrior", "Warlock", "Paladin", "Priest", "Rogue", "Shaman" }
--  Transaction log: Contains a list of { timestamp, tid, description, state, { names, dkp } }
--	Transaction state: 0=Rolled back, 1=Active (default), 
local transactionLog = {}
--	Current transactionID, starts out as 0 (=none).
local currentTransactionID = 0
--	Sync.state: 0=idle, 1=initializing, 2=synchronizing
local synchronizationState = 0
--	Hold RX_SYNCINIT responses when querying for a client to sync.
local syncResults = {}




--  *******************************************************
--
--	Slash commands
--
--  *******************************************************

--[[
	Display DKP for a specific user, or current user if no playername was given.
	Syntax: /gddkp [<player>]
]]
SLASH_GUILDDKP_STATUS_DKP1 = "/gddkp"
SLASH_GUILDDKP_STATUS_DKP2 = "/dkp"
SlashCmdList["GUILDDKP_STATUS_DKP"] = function(msg)
	local _, _, name = string.find(msg, "(%S*).*")

	if canReadNotes() then	
		if not name or name == "" then
			name = UnitName("player")
		end
	
		if isInRaid(true) then
			if table.getn(raidRoster) > 0 then
				displayDKPForRaidingPlayer(name)
			else
				AddJob( function(job) displayDKPForRaidingPlayer(job[2]) end, name, "_" )
				requestUpdateRoster()
			end
		else
			if table.getn(guildRoster) > 0 then
				displayDKPForGuildedPlayer(name)
			else
				AddJob( function(job) displayDKPForGuildedPlayer(job[2]) end, name, "_" )
				requestUpdateRoster()   
			end
		end
    end
end



--[[
	Display DKP values for all of a certain class
	Class defaults to current user's class if not given.
	Syntax: /gdclass [<class>]
]]
SLASH_GUILDDKP_CLASS1 = "/gdclass"
SLASH_GUILDDKP_CLASS2 = "/classdkp"
SlashCmdList["GUILDDKP_CLASS"] = function(msg)
	local _, _, classname = string.find(msg, "(%S*).*")

	if not classname or classname == "" then
		classname = UnitClass("player")
	end
	
	if not checkClass(classname) then
		GuildDKP_Echo("'"..UCFirst(classname).."' is not a valid class.")
		return
	end	
	
	if canReadNotes() then
		if isInRaid(true) then
			if table.getn(raidRoster) > 0 then
				displayDKPForRaidingClass(classname)
			else
				AddJob( function(job) displayDKPForRaidingClass(job[2]) end, classname, "_" )
				requestUpdateRoster()   
			end
		else
			if table.getn(guildRoster) > 0 then
				displayDKPForGuildedClass(classname)
			else
				AddJob( function(job) displayDKPForGuildedClass(job[2]) end, classname, "_" )
				requestUpdateRoster()
			end
		end
	end
end



--[[
	Add DKP to a specific char and announce in /RW
	Syntax: /gdplus <player> <dkp value>
]]
SLASH_GUILDDKP_PLUS_DKP1 = "/gdplus"
SLASH_GUILDDKP_PLUS_DKP2 = "/gdp"
SlashCmdList["GUILDDKP_PLUS_DKP"] = function(msg)
	local _, _, name, dkp = string.find(msg, "(%S*)%s*(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and name and tonumber(dkp) then
			AddJob( GDPlus_callback, name, dkp )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdplus <name> <dkp value>")
		end
	end
end

function GDPlus_callback(job)
	local name = UCFirst(job[2])
	local dkp = job[3]

	if applyDKP(name, dkp) then	
		logSingleTransaction("GDPlus", name, dkp)
		SendChatMessage(dkp.." DKP has been added to "..name..".", RAID_CHANNEL)
	end
end



--[[
	Remove DKP from a specific char and announce in /RW
	Syntax: /gdminus <player> <dkp value>
]]
SLASH_GUILDDKP_MINUS_DKP1 = "/gdminus"
SLASH_GUILDDKP_MINUS_DKP2 = "/gdm"
SlashCmdList["GUILDDKP_MINUS_DKP"] = function(msg)
	local _, _, name, dkp = string.find(msg, "(%S*)%s*(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and name and tonumber(dkp) then
			AddJob( GDMinus_callback, name, dkp )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdminus <name> <dkp value>")
		end
	end    
end

function GDMinus_callback(job)
	local name = UCFirst(job[2])
	local dkp = job[3]

	if applyDKP(name, (-1 * dkp)) then
		logSingleTransaction("GDMinus", name, (-1 * dkp))
		SendChatMessage(dkp.." DKP was subtracted from "..name..".", RAID_CHANNEL)
	end
end
 


--[[
	Remove % DKP from a specific char and announce in Raid Warning.
	A minimum of 50 DKP is withdrawn.
	Syntax: /gdminuspct <player> <percent>
]]
SLASH_GUILDDKP_MINUS_PERCENT1 = "/gdminuspct"
SLASH_GUILDDKP_MINUS_PERCENT2 = "/minuspct"
SlashCmdList["GUILDDKP_MINUS_PERCENT"] = function(msg)
	local _, _, name, pct = string.find(msg, "(%S*)%s*(%d*).*")

	if isInRaid() and canWriteNotes() then
		if pct and name and tonumber(pct) then
			AddJob( GDMinusPercent_callback, name, pct )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdminuspct <name> <percent>")
		end
	end    
end

function GDMinusPercent_callback(job)
	local name = UCFirst(job[2])
	local pct = job[3]

	local dkp = getDKP(name)
	if tonumber(dkp) then
		local amount = floor(dkp * pct / 100)
		if amount < 50 then
			amount = 50
		end
		if applyDKP(name, (-1 * amount)) then
			logSingleTransaction("GDMinusPct", name, (-1 * amount))
			SendChatMessage(amount.." DKP (".. pct.."%) was subtracted from "..name..".", RAID_CHANNEL)
		end	
	else
	   	GuildDKP_Echo(name.." was not found in the guild; DKP was not updated.")
	end
end



--[[
	Add DKP to all guild members in the current raid.
	Syntax: /gdaddraid <dkp value>
]]
SLASH_GUILDDKP_ADD_RAID1 = "/gdaddraid"
SLASH_GUILDDKP_ADD_RAID2 = "/addraid"
SlashCmdList["GUILDDKP_ADD_RAID"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and tonumber(dkp) then
			AddJob( GDAddRaid_callback, dkp, "_" )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdaddraid <dkp>")
		end
	end    
end

function GDAddRaid_callback(job)
	local dkp = job[2]
	addRaidDKP(dkp, "GDAddRaid")
	SendChatMessage(dkp.." DKP has been added to all players in raid.", RAID_CHANNEL)
end



--[[
	Subtract DKP from all guild members in the current raid.
	Syntax: /gdsubtractraid <dkp value>
]]
SLASH_GUILDDKP_SUBTRACT_RAID1 = "/gdsubtractraid"
SLASH_GUILDDKP_SUBTRACT_RAID2 = "/subtractraid"
SlashCmdList["GUILDDKP_SUBTRACT_RAID"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and tonumber(dkp) then
			AddJob( GDSubtractRaid_callback, dkp, "_" )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdsubtractraid <dkp>")
		end
	end    
end

function GDSubtractRaid_callback(job)
	local dkp = job[2]
	subtractRaidDKP(dkp, "GDSubtractRaid")
	SendChatMessage(dkp.." DKP has been subtracted from all players in raid.", RAID_CHANNEL)
end



--[[
	Add DKP to all people in range (100 yards)
	Syntax: /gdaddrange
]]
SLASH_GUILDDKP_ADD_RANGE1 = "/gdaddrange"
SLASH_GUILDDKP_ADD_RANGE2 = "/addrange"
SlashCmdList["GUILDDKP_ADD_RANGE"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and tonumber(dkp) then
			AddJob( GDAddRange_callback, dkp, "_" )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdaddrange <dkp value>")
		end
	end
end

function GDAddRange_callback(job)
	local dkp = job[2]
	local updateCount = 0

	local tidIndex = 1
	local tidChanges = {}
	
	for n=1, 40, 1 do
		local unitid = "raid"..n
		local player = UnitName(unitid)
		local isOnline = UnitIsConnected(unitid)

		if player then		
			if isOnline and UnitIsVisible(unitid) then
				updateCount = updateCount + 1
				applyDKP(player, dkp)
				
				tidChanges[tidIndex] = { player, dkp }
				tidIndex = tidIndex + 1				
			end
		end
	end
	
	logMultipleTransactions("GDAddRange", tidChanges)
	SendChatMessage(dkp.." DKP has been added for "..updateCount.." players in range.", RAID_CHANNEL)
end



--[[
	Share DKP to all guild members in the current raid.
	Syntax: /gdshareraid <dkp value>
]]
SLASH_GUILDDKP_SHARE_RAID1 = "/gdshareraid"
SLASH_GUILDDKP_SHARE_RAID2 = "/shareraid"
SlashCmdList["GUILDDKP_SHARE_RAID"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and tonumber(dkp) then
			AddJob( GDShareRaid_callback, dkp, "_" )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdshareraid <dkp>")
		end
	end    
end

function GDShareRaid_callback(job)
	local dkp = job[2]
	
	local members = GetNumRaidMembers()
	if(members > 0) then
		local sharedDkp = ceil(dkp / members)
	
		addRaidDKP(sharedDkp, "GDShareRaid")
		SendChatMessage(dkp.." DKP has been shared, giving "..sharedDkp.." DKP to each player.", RAID_CHANNEL)
	end
end



--[[
	Share DKP to all people in range (100 yards)
	Each member will get <dkp>/<# of members in range> DKP.
	Syntax: /gdsharerange <dkp>
]]
SLASH_GUILDDKP_SHARE_RANGE1 = "/gdsharerange"
SLASH_GUILDDKP_SHARE_RANGE2 = "/sharerange"
SlashCmdList["GUILDDKP_SHARE_RANGE"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if isInRaid() and canWriteNotes() then
		if dkp and tonumber(dkp) then
			AddJob( GDShareRange_callback, dkp, "_" )
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdsharerange <dkp value>")
		end
	end
end

function GDShareRange_callback(job)
	local dkp = job[2]

	--	Run through list twice:
	--	First loop: count # of members in range
	local unitid
	local members = 0
	for n=1, 40, 1 do
		unitid = "raid"..n
		if UnitName(unitid) and UnitIsConnected(unitid) and UnitIsVisible(unitid) then
			members = members + 1
		end
	end	

	if members > 0 then		
		local tidIndex = 1
		local tidChanges = {}

		--	Second loop: apply the DKP:
		local sharedDkp = ceil(dkp / members)
		for n=1, 40, 1 do
			unitid = "raid"..n
			if UnitName(unitid) and UnitIsConnected(unitid) and UnitIsVisible(unitid) then
				applyDKP(UnitName(unitid), sharedDkp)
				tidChanges[tidIndex] = { UnitName(unitid), sharedDkp }
				tidIndex = tidIndex + 1
			end
		end
		logMultipleTransactions("GDShareRange", tidChanges)	
		SendChatMessage(dkp.." DKP has been added, giving "..sharedDkp.." to "..members.." players in range.", RAID_CHANNEL)
	end
end



--[[
	Subtract DKP from all guild members. This is not from raid only.
	Note: this will *fail* if Offline people are not visible.
	Syntax: /gddecay
]]
SLASH_GUILDDKP_DECAY1 = "/gddecay"
SlashCmdList["GUILDDKP_DECAY"] = function(msg)
	local _, _, dkp = string.find(msg, "(%d*).*")

	if canWriteNotes() then
		AddJob( function(job) decayDKP(job[2]) end, dkp, "_" )
		requestUpdateRoster()
	end
end



--[[
	Show transaction log from transaction id <id>.
	Defaults to the last 5 transactions.
	Syntax: /gdlog [<transaction id>]
]]
SLASH_GUILDDKP_LOG1 = "/gdlog"
SLASH_GUILDDKP_LOG2 = "/dkplog"
SlashCmdList["GUILDDKP_LOG"] = function(msg)
	local _, _, transactionID = string.find(msg, "(%d*).*")

	if not transactionID or transactionID == "" or not tonumber(transactionID) then
		transactionID = 0
	end

	if tonumber(transactionID) then
		showTransactionLog(transactionID)
	else
		GuildDKP_Echo("Syntax: /gdlog [<transaction id>]")
	end
end


--[[
	Show transaction log details (usefull for transactions with many players)
	Syntax: /gdlogdetails <transaction id>
]]
SLASH_GUILDDKP_LOGDETAILS1 = "/gdlogdetails"
SLASH_GUILDDKP_LOGDETAILS2 = "/logdetails"
SlashCmdList["GUILDDKP_LOGDETAILS"] = function(msg)
	local _, _, transactionID = string.find(msg, "(%d*).*")

	if tonumber(transactionID) then
		showTransactionDetails(transactionID)
	else
		GuildDKP_Echo("Syntax: /gdlogdetails <transaction id>")
	end
end


--[[
	Show transaction log details in guildchat (usefull for transactions with many players)
	Syntax: /gdpostlog <transaction id>
]]
SLASH_GUILDDKP_POSTLOG1 = "/gdpostlog"
SLASH_GUILDDKP_POSTLOG2 = "/postlog"
SlashCmdList["GUILDDKP_POSTLOG"] = function(msg)
	local _, _, transactionID = string.find(msg, "(%d*).*")

	if tonumber(transactionID) then
		showTransactionDetailsInGuildChat(transactionID)
	else
		GuildDKP_Echo("Syntax: /gdpostlog <transaction id>")
	end
end


--[[
	Undo specific transaction (rollback transaction)
	Syntax: /gdundo [<transaction id>]
]]
SLASH_GUILDDKP_UNDO1 = "/gdundo"
SlashCmdList["GUILDDKP_UNDO"] = function(msg)
	local _, _, transactionID = string.find(msg, "(%d*).*")

	if transactionID and tonumber(transactionID) then
		AddJob( function(job) undoTransaction(job[2]) end, transactionID, "_" )
		requestUpdateRoster()
	else
		GuildDKP_Echo("Syntax: /gdundo [<transaction id>]")
	end
end



--[[
	Redo specific transaction (cancel rollback)
	Syntax: /gdundo [<transaction id>]
]]
SLASH_GUILDDKP_REDO1 = "/gdredo"
SlashCmdList["GUILDDKP_REDO"] = function(msg)
	local _, _, transactionID = string.find(msg, "(%d*).*")

	if transactionID and tonumber(transactionID) then
		AddJob( function(job) redoTransaction(job[2]) end, transactionID, "_" )
		requestUpdateRoster()
	else
		GuildDKP_Echo("Syntax: /gdredo [<transaction id>]")
	end
end


--[[
	Include (add) a player to a (typical multiplayer) transaction.
	Syntax: /gdinclude <player> <transaction id>
]]
SLASH_GUILDDKP_INCLUDE1 = "/gdinclude"
SlashCmdList["GUILDDKP_INCLUDE"] = function(msg)
	local _, _, name, transactionID = string.find(msg, "(%S*)%s*(%d*).*")

	if transactionID and name and tonumber(transactionID) then
		AddJob( function(job) includePlayerInTransaction(job[2], job[3]) end, transactionID, name)
		requestUpdateRoster()
	else
		GuildDKP_Echo("Syntax: /gdinclude <name> <transaction id>")
	end
end



--[[
	Exclude (remove) a player from a (typical multiplayer) transaction.
	Syntax: /gdexclude <transaction id> <player>
]]
SLASH_GUILDDKP_EXCLUDE1 = "/gdexclude"
SlashCmdList["GUILDDKP_EXCLUDE"] = function(msg)
	local _, _, name, transactionID = string.find(msg, "(%S*)%s*(%d*).*")

	if transactionID and name and tonumber(transactionID) then
		AddJob( function(job) excludePlayerInTransaction(job[2], job[3]) end, transactionID, name)
		requestUpdateRoster()
	else
		GuildDKP_Echo("Syntax: /gdexclude <transaction id> <name>")
	end
end



--[[
	Synchronize the transaction log with others.
	Syntax: /gdsynchronize
]]
SLASH_GUILDDKP_SYNCHRONIZE1 = "/gdsynchronize"
SLASH_GUILDDKP_SYNCHRONIZE2 = "/gdsync"
SlashCmdList["GUILDDKP_SYNCHRONIZE"] = function(msg)
	if synchronizationState == 0 then
		synchronizeTransactionLog();
	else
		GuildDKP_Echo("A synchronization task is already running!");
	end
end



--[[
	Display current configuration options.
]]
SLASH_GUILDDKP_CONFIG1 = "/gdconfig"
SlashCmdList["GUILDDKP_CONFIG"] = function()
	GuildDKP_Echo("Current DKP string length: ".. GDKP_DkpStringLength);
	GuildDKP_Echo("Current debug level: ".. GDKP_DebugLevel);
end



--[[
	Get or Set Debug level.
	If no param is given, the function outputs the current debug level.
	If a (numeric) param is given, this will be used as the new debug level.
]]
SLASH_GUILDDKP_DEBUGLEVEL1 = "/gddebug"
SlashCmdList["GUILDDKP_DEBUGLEVEL"] = function(msg)
	local _, _, debugLevel = string.find(msg, "(%d*).*")

	if debugLevel and tonumber(debugLevel) then
		GDKP_DebugLevel = debugLevel
		GuildDKP_Echo("Debug level set to ".. GDKP_DebugLevel);			
	else
		GuildDKP_Echo("Syntax: /gddebug <debug level [0-1]>"..debugLevel)
	end
end



--[[
	Get or Set DKP string lengrh
	If no param is given, the function outputs the current DKP string length
	If a (numeric) param is given, this will be used as the new DKP string length
]]
SLASH_GUILDDKP_DKP_LENGTH1 = "/gddkplength"
SLASH_GUILDDKP_DKP_LENGTH2 = "/dkplength"
SlashCmdList["GUILDDKP_DKP_LENGTH"] = function(msg)
	local _, _, dkpLength = string.find(msg, "(%d*).*")

	if dkpLength and tonumber(dkpLength) then
		GDKP_DkpStringLength = dkpLength
		GuildDKP_Echo("DKP string length set to ".. GDKP_DkpStringLength);
	else
		GuildDKP_Echo("Syntax: /gddkplength <DKP string length [0 - 6]>")
	end
end



--[[
	Display names of all players in combat - used to detect combat bugged people.
	if "raid" parameter, the names will be displayed in the raid chat.
	Syntax: /gdcombat [raid]
]]
SLASH_GUILDDKP_CHECKCOMBAT1 = "/gdcombat"
SLASH_GUILDDKP_CHECKCOMBAT2 = "/checkcombat"
SlashCmdList["GUILDDKP_CHECKCOMBAT"] = function(msg)
	local _, _, chatparam = string.find(msg, "(%S*).*")
	local message = nil
	
	if isInRaid(true) then
		for n=1, 40, 1 do
			local unitid = "raid"..n
			local player = UnitName(unitid)

			if player then		
				if UnitIsConnected(unitid) and UnitAffectingCombat(unitid) then
					if message then
						message = message ..", ".. player
					else
						message = player
					end			
				end
			end
		end	
		
		if message then
			if chatparam and UCFirst(chatparam) == "Raid" then
				SendChatMessage("The following players are in combat:", RAID_CHANNEL)
				SendChatMessage(message, RAID_CHANNEL)
			else
				GuildDKP_Echo("The following players are in combat:")
				GuildDKP_Echo(message)
			end
		else
			if chatparam and UCFirst(chatparam) == "Raid" then
				SendChatMessage("No players are in combat.", RAID_CHANNEL)
			else
				GuildDKP_Echo("No players are in combat.")
			end		
		end	
	end
end



--[[
	Check if people are within range (100 yards)
	if "raid" parameter, the names will be displayed in the raid chat.
	Syntax: /gdrange [raid], /checkrange [raid]	
]]
SLASH_GUILDDKP_CHECKRANGE1 = "/gdrange"
SLASH_GUILDDKP_CHECKRANGE2 = "/checkrange"
SlashCmdList["GUILDDKP_CHECKRANGE"] = function(msg)
	local _, _, chatparam = string.find(msg, "(%S*).*")
	local message = nil
	
	if isInRaid() then
		for n=1, 40, 1 do
			local unitid = "raid"..n
			local player = UnitName(unitid)
			local isOnline = UnitIsConnected(unitid)

			if player then		
				if isOnline and UnitIsVisible(unitid) then
					-- Player is visible (in range), do nothing
				else
					if message then
						message = message ..", ".. player
					else
						message = player
					end			
				end
			end
		end	
		
		if message then
			if chatparam and UCFirst(chatparam) == "Raid" then
				SendChatMessage("The following players are not in range:", RAID_CHANNEL)
				SendChatMessage(message, RAID_CHANNEL)
			else
				GuildDKP_Echo("The following players are not in range:")
				GuildDKP_Echo(message)
			end
		else
			if chatparam and UCFirst(chatparam) == "Raid" then
				SendChatMessage("All players are in range.", RAID_CHANNEL)
			else
				GuildDKP_Echo("All players are in range")
			end
		end	
	end
end



--[[
	Request a version check for all GuildDKP clients in raid.
	This is done by sending a "gdrequestversion" message in the Addon channel.
	Results are displayed to local user.
	Syntax: /gdversion, /gdcheckversion
]]
SLASH_GUILDDKP_CHECKVERSION1 = "/gdversion"
SLASH_GUILDDKP_CHECKVERSION2 = "/gdcheckversion"
SlashCmdList["GUILDDKP_CHECKVERSION"] = function()
	local message = nil
	
	if isInRaid(true) then
		SendAddonMessage(GUILDDKP_PREFIX, "TX_VERSION##", "RAID")
	else
		GuildDKP_Echo( string.format("%s is using GuildDKP version %s", UnitName("player"), GetAddOnMetadata("GuildDKP", "Version")) );
	end
end


--[[
	Display help (command syntax)
	Syntax: /gdhelp
]]
SLASH_GUILDDKP_HELP1 = "/gdhelp"
SlashCmdList["GUILDDKP_HELP"] = function()
	GuildDKP_Echo("GuildDKP version "..GetAddOnMetadata("GuildDKP", "Version") .." - available commands:")
	GuildDKP_Echo("/gdconfig  --  Display current configuration settings")
	GuildDKP_Echo("/gddkplength  --  Set the length of the DKP value string in guild notes")
	GuildDKP_Echo("")
	GuildDKP_Echo("Queries:")
	GuildDKP_Echo("/gddkp <player>	 --  Display how much DKP <player> owns.")
	GuildDKP_Echo("/gdclass <class>  --  Display DKP for all players of <class>.")
	GuildDKP_Echo("/gdcombat [channel] --  Display players currently in combat.")
	GuildDKP_Echo("/gdrange [channel]  --  Display players not within 100 yards range.")
	GuildDKP_Echo("/gdversion --  Request version information (if any) for all players in raid.")
	GuildDKP_Echo("")
	GuildDKP_Echo("DKP control:")
	GuildDKP_Echo("/gdplus <player> <amount>  --  Add <amount> DKP to <player> and announce in raid.")
	GuildDKP_Echo("/gdminus <player> <amount>  --  Subtract <amount> DKP from <player> and announce in raid.")
	GuildDKP_Echo("/gdminuspct <player> <percent>  --  Subtract <percemt> % DKP from <player> and announce in raid.")
	GuildDKP_Echo("/gdaddraid <amount>  --  Add <amount> DKP to all players in the raid.")
	GuildDKP_Echo("/gdaddrange <amount>  --  Add <amount> DKP to players within 100 yards range")
	GuildDKP_Echo("/gdshareraid <amount>  --  Share <amount> DKP to all players in the raid.")
	GuildDKP_Echo("/gdsharerange <amount>  --  Share <amount> DKP to players within 100 yards range")
	GuildDKP_Echo("/gdsubtractraid <amount>  --  Subtract <amount< DKP from all players in the raid.")
	GuildDKP_Echo("/gddecay <percent>  --  Subtract <percent> % DKP from all players in the guild.")
	GuildDKP_Echo("")
	GuildDKP_Echo("Transaction control:")
	GuildDKP_Echo("/gdlog [lines]  --  List the last [lines] transactions, defaults to 10.")
	GuildDKP_Echo("/gdlogdetails <transaction id>]  --  List details for one transaction.")
	GuildDKP_Echo("/gdpostlog <transaction id>]  --  List details for one transaction in raid.")
	GuildDKP_Echo("/gdundo <transaction id>  --  Rollback specific transaction")
	GuildDKP_Echo("/gdredo <transaction id>  --  Cancel transaction rollback")
	GuildDKP_Echo("/gdexclude <player> <transaction id>  --  Remove player from a transaction")
	GuildDKP_Echo("/gdinclude <player> <transaction id>  --  Add player to a transaction")
end




--  *******************************************************
--
--	DKP Functions
--
--  *******************************************************

--[[
	Add DKP to all (online) guilded raid members.
]]
function addRaidDKP(dkp, description)
	local playerCount = GetNumRaidMembers()
		
	if playerCount then
		local tidIndex = 1
		local tidChanges = {}

		for n=1,playerCount,1 do
			local name = GetRaidRosterInfo(n)
			applyDKP(name, dkp)
			
			tidChanges[tidIndex] = { name, dkp }
			tidIndex = tidIndex + 1
		end	

		logMultipleTransactions(description, tidChanges)
	end
end


--[[
	Subtract DKP from all (online) guilded raid members.
]]
function subtractRaidDKP(dkp, description)
	local playerCount = GetNumRaidMembers()
	
	if playerCount then
		local tidIndex = 1
		local tidChanges = {}
	
		for n=1,playerCount,1 do
			local name = GetRaidRosterInfo(n)
			applyDKP(name, -1 * dkp)
			
			tidChanges[tidIndex] = { name, (-1 * dkp) }
			tidIndex = tidIndex + 1
		end	

		logMultipleTransactions(description, tidChanges)
	end
end


--[[
	Subtract DKP from all players in guild based on our decay metrics
]]
function decayDKP(percent)

	local playerCount = table.getn(guildRoster)
	local currentPlayer = UnitName("player")
	local updateCount = 0
	local reducedDkp = 0


	--	This ensure the guild roster also contains Offline members.
	--	The drawback is that the user cannot untick the "Show Offline Members" in the UI,
	--	but it is the only way we can display DKP for offline's also.
	if not GetGuildRosterShowOffline() then
		GuildDKP_Echo("Guild Decay cancelled: You need to enable Offline Guild Members in the guild roster first.")
		return
	end

	local tidIndex = 1
	local tidChanges = {}

	--	Iterate over all guilded players - online or not
	for n=1,playerCount,1 do
		local player = guildRoster[n]
		local name = player[1]
		local dkp = player[2]
		
		local minus = 0
		if dkp > 400 then
			if dkp < 800 then
				minus = math.floor((dkp - 400) * 0.25)
			else
				minus = math.floor((dkp - 800) * 0.5 + 100)
			end
		end
		
		if minus > 0 then
			tidChanges[tidIndex] = { name, (-1 * minus) }
			tidIndex = tidIndex + 1
		
			reducedDkp = reducedDkp + minus
			updateCount = updateCount + 1
						
			applyDKP(name, -1 * minus)
		end
	end
	
	logMultipleTransactions("GDDecay", tidChanges)
	
	SendChatMessage("Guild DKP decay was performed by "..currentPlayer..".", GUILD_CHANNEL)
	SendChatMessage("Guild DKP removed a total of "..reducedDkp.." DKP from ".. updateCount .." players.", GUILD_CHANNEL)
end


--[[
	Get DKP belonging to a specific player.
	Returns FALSE if player was not found. Players with no DKP will return 0.
]]
function getDKP(receiver)
	local memberCount = GetNumGuildMembers()
	local dkpValue = 0

	for n=1,memberCount,1 do
		name, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(n)
		local note = publicNote
		if name == receiver then
			if useOfficerNotes then
				note = officerNote
			end
		
			local _, _, dkp = string.find(note, "<(-?%d*)>")

			if dkp and tonumber(dkp)  then
				dkpValue = (1 * dkp)
			end
			return dkpValue		
		end
   	end
   	return false
end



--[[
	Apply DKP to a specific player.
	Returns FALSE if DKP could not be applied.
]]
function applyDKP(receiver, dkpValue)
	local memberCount = GetNumGuildMembers()

	for n=1,memberCount,1 do
		name, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(n)
		local note = publicNote
		if name == receiver then
			if useOfficerNotes then
				note = officerNote
			end
		
			local _, _, dkp = string.find(note, "<(-?%d*)>")

			if dkp and tonumber(dkp)  then
				dkp = (1 * dkp) + dkpValue
				note = string.gsub(note, "<(-?%d*)>", createDkpString(dkp), 1)
			else
				dkp = dkpValue
				note = note..createDkpString(dkp)
			end
			
			if useOfficerNotes then
				GuildRosterSetOfficerNote(n, note)
			else			
				GuildRosterSetPublicNote(n, note)
			end
			applyLocalDKP(name, dkp)			
			return true		
		end
   	end
   	GuildDKP_Echo(receiver.." was not found in the guild; DKP was not updated.")
   	return false
end

function createDkpString(dkp)
	local result
	
	if not dkp or dkp == "" or not tonumber(dkp) then
		dkp = 0
	end
	dkp = tonumber(dkp)
	
	local dkpLen = tonumber(GDKP_DkpStringLength)
	if dkpLen > 0 then
		local dkpStr = "".. abs(dkp)
		while string.len(dkpStr) < dkpLen do
			dkpStr = "0"..dkpStr
		end
		if dkp < 0 then
			dkpStr = "-"..dkpStr
		end				
		result = "<"..dkpStr..">"		
	else
		result = "<"..dkp..">"
	end
	return result
end



--[[
	Apply DKP to local loaded list
	Input: receiver, dkpadded
]]
function applyLocalDKP(receiver, dkpAdded)
	for n=1, table.getn(raidRoster),1 do
		local player = raidRoster[n]
		local name = player[1]
		local dkp = player[2]
		local class = player[3]
		local online = player[4]

		if receiver == name then
			if dkp then
				dkp = dkp + dkpAdded
			else
				dkp = dkpAdded
			end
			raidRoster[n] = {name, dkp, class, online}
			return
		end
	end
end



--[[
	Display DKP amount for a specific player (locally) in the raid
]]
function displayDKPForRaidingPlayer(receiver)
	receiver = UCFirst(receiver)
	local player = getRaidPlayer(receiver)
	
	if player then
		local dkp = player[2]
				
		if dkp then
			GuildDKP_Echo(receiver.." currently has "..dkp.." DKP.")
		else
			GuildDKP_Echo(receiver.." does not have any DKP.")
		end
	else
		GuildDKP_Echo(receiver.." was not found in raid.")
	end	
end



--[[
	Display DKP amount for a specific player (locally) in the guild
]]
function displayDKPForGuildedPlayer(receiver)
	receiver = UCFirst(receiver)
	local player = getGuildPlayer(receiver)
	
	if player then
		local dkp = player[2]	
		if dkp then
			GuildDKP_Echo(receiver.." currently has "..dkp.." DKP.")
		else
			GuildDKP_Echo(receiver.." does not have any DKP.")
		end
	else
		GuildDKP_Echo(receiver.." was not found in guild.")
	end	
end



--[[
	Display DKP amount for a specific class (locally) in the raid
	Input: class name
	Output: (list of players with dkp directly to local screen)
]]
function displayDKPForRaidingClass(classname)
	classname = UCFirst(classname)

	local classMembers = {}
	local classCount = 1
	for n=1, table.getn(raidRoster),1 do
		local player = raidRoster[n]
		local name = player[1]
		local dkp = player[2]
		local class = player[3]
		local online = player[4]

		if class == classname then
			classMembers[classCount] = {name, dkp, online}
			classCount = classCount + 1
		end
	end

	-- Sort the DKP list with highest DKP in top.
	local doSort = true
	while doSort do
		doSort = false
		for n=1,table.getn(classMembers) - 1,1 do
			local a = classMembers[n]
			local b = classMembers[n + 1]
			if tonumber(a[2]) and tonumber(b[2]) and tonumber(a[2]) < tonumber(b[2]) then
				classMembers[n] = b
				classMembers[n + 1] = a
				doSort = true
			end
		end
	end

	if table.getn(classMembers) > 0 then
		for n=1,table.getn(classMembers),1 do
			local rec = classMembers[n]
			local name = rec[1]
			local dkp = rec[2]
			local online = rec[3]
			
			if not online then
				name = name.." (Offline)"
			end
			
			if dkp then
				GuildDKP_Echo(name.." currently has "..dkp.." DKP.")
			else
				GuildDKP_Echo(name.." does not have any DKP.")
			end		
		end		
	else
		GuildDKP_Echo("No "..classname.."s was found in raid.")
	end
end



--[[
	Display DKP amount for a specific class (locally) in the guild
	This shows DKP for all members of a specific class, regardless
	if they are in the raid or not - or even offline.
	Input: class name
	Output: (list of players with dkp directly to local screen)
]]
function displayDKPForGuildedClass(classname)
	classname = UCFirst(classname)
	
	local classMembers = {}
	local classCount = 0
	local memberCount = GetNumGuildMembers()
	
	--	First get all players of the wanted class
	for n=1,memberCount,1 do
		local player = guildRoster[n]
		local name = player[1]
		local dkp = player[2]
		local class = player[3]

		if class == classname then
			classCount = classCount + 1
			classMembers[classCount] = {name, dkp}
		end
	end
	
	-- Then Sort the DKP list with highest DKP in top.
	local doSort = true
	while doSort do
		doSort = false
		for n=1,table.getn(classMembers) - 1,1 do
			local a = classMembers[n]
			local b = classMembers[n + 1]
			if tonumber(a[2]) and tonumber(b[2]) and tonumber(a[2]) < tonumber(b[2]) then
				classMembers[n] = b
				classMembers[n + 1] = a
				doSort = true
			end
		end
	end

	--	Last, display the results (up to MAX members)
	if table.getn(classMembers) > 0 then
		local totalCount = classCount
		if classCount > maxClassMembersShown then
			classCount = maxClassMembersShown
		end
		
		GuildDKP_Echo("Showing "..classCount.." out of "..totalCount.." "..classname.."s:")
		for n=1,classCount,1 do
			local rec = classMembers[n]
			local name = rec[1]
			local dkp = rec[2]		
			if dkp then
				GuildDKP_Echo(name.." currently has "..dkp.." DKP.")
			else
				GuildDKP_Echo(name.." does not have any DKP.")
			end		
		end		
	else
		GuildDKP_Echo("No "..classname.."s was found in the guild.")
	end	
end




--  *******************************************************
--
--	Roster Functions
--
--  *******************************************************

--[[
	Update the guild roster status cache: members and DKP.
	Used to display DKP values for non-raiding members
	(/gdclass and /gdstat)
]]
function refreshGuildRoster()
	local memberCount = GetNumGuildMembers()

	guildRoster = {}

	local note
	local index = 1	
	for m=1,memberCount,1 do
		local name, _, _, _, class, _, publicnote, officernote, online = GetGuildRosterInfo(m)

		if useOfficerNotes then		
			note = officernote
		else
			note = publicnote
		end
		
		if not note or note == "" then
			note = "<0>"
		end
		
		
		local _, _, dkp = string.find(note, "<(-?%d*)>")
		if not dkp then
			dkp = 0
		end
		guildRoster[index] = { name, (1 * dkp), class }
		index = index + 1	
	end
end


--[[
	Re-read the raid status and namely the DKP values.
	Should be called after each roster update.
]]
function refreshRaidRoster()
	local playerCount = GetNumRaidMembers()
	
	if playerCount then
		--	name, rank, rankIndex, level, class, zone, note, officernote
		local members = {}
		local memberCount = GetNumGuildMembers()

		--	Loop over all _online_ players
		local index = 0
		for m=1,memberCount,1 do
			local name, _, _, _, class, _, publicnote, officernote, online = GetGuildRosterInfo(m)				
			index = index + 1
			if useOfficerNotes then
				members[index] = { name, officernote, class, online }
			else
				members[index] = { name, publicnote, class, online }
			end
		end

		raidRoster = {}
		local index = 1
		for n=1,playerCount,1 do
			local name, _, _, _, class = GetRaidRosterInfo(n)			

			for m=1,memberCount,1 do
				local info = members[m]
				if name == info[1] then
					local _, _, dkp = string.find(info[2], "<(-?%d*)>")
					if not dkp then
						dkp = 0
					end
					raidRoster[index] = { name, (1 * dkp), class, info[4] }
					index = index + 1
				end
			end
		end
	end	
end


--[[
	Return the amount of DKP a specific player in the raid currently has.
	Input: player name
	Output: DKP value, or nil if player was not found.
]]
function getRaidPlayer(receiver)
	for n=1, table.getn(raidRoster),1 do
		local player = raidRoster[n]
		local name = player[1]
		local dkp = player[2]
		local class = player[3]
		local online = player[4]
		
		if name == receiver then
			return { name, dkp, class, online }
		end
	end
	return nil
end


--[[
	Return the amount of DKP a specific player in the guild currently has.
	Input: player name
	Output: DKP value, or nil if player was not found.
]]
function getGuildPlayer(receiver)
	for n=1, table.getn(guildRoster),1 do
		local player = guildRoster[n]
		local name = player[1]
		local dkp = player[2]
		local class = player[3]
		
		if name == receiver then
			return { name, dkp, class }
		end
	end
	return nil
end

function requestUpdateRoster()
	GuildRoster()
end

function handleGuildRosterUpdate()
	if canReadNotes() then
		if not jobRunning then	
			jobRunning = true
			
			local job = getNextJob()
			while job do
				job[1](job)
				
				job = getNextJob()
			end
			
			refreshGuildRoster()

			if isInRaid(true) then
				refreshRaidRoster()
			end

			jobRunning = false
		end
	end
end




--  *******************************************************
--
--	Helper Functions
--
--  *******************************************************

function canReadNotes()
	if useOfficerNotes then
		result = canReadOfficerNotes()
	else
		result = canReadGuildNotes()
	end
	return result
end

function canWriteNotes()
	if useOfficerNotes then
		result = canWriteOfficerNotes()
	else
		result = canWriteGuildNotes()
	end
	return result
end

function canReadGuildNotes()
	return true
end

function canReadOfficerNotes()
	local result = CanViewOfficerNote()
	if not result then
		GuildDKP_Echo("Sorry, but you do not have access to read officer notes.")
	end
	return result
end

function canWriteGuildNotes()
	local result = canReadGuildNotes() and CanEditPublicNote()
	if not result then
		GuildDKP_Echo("Sorry, but you do not have access to write guild notes.")
	end
	return result	
end

function canWriteOfficerNotes()
	local result = CanViewOfficerNote() and CanEditOfficerNote()
	if not result then
		GuildDKP_Echo("Sorry, but you do not have access to write officer notes.")
	end
	return result	
end

function isInRaid(silentMode)
	local result = ( GetNumRaidMembers() > 0 )
	if not silentMode and not result then
		GuildDKP_Echo("You must be in a raid!")
	end
	return result
end

--[[
	Remove all empty rows from a table, effectibely renumbering table.
]]
function packTable(sourcetable)
	local destinationtable = {}
	local index = 1
	for n = 1, table.getn(sourcetable), 1 do
		local row = sourcetable[n]		
		if table.getn(row) > 0 then
			destinationtable[index] = row
			index = index + 1
		end
	end	
	return destinationtable
end


--[[
	Sort table using specific column index in ascending order
]]
function sortTableAscending(sourcetable, columnindex)
	local doSort = true
	while doSort do
		doSort = false
		for n=table.getn(sourcetable), 2, -1 do
			local row1 = sourcetable[n - 1]
			local row2 = sourcetable[n]
			if row1[columnindex] > row2[columnindex] then
				sourcetable[n - 1] = row2
				sourcetable[n] = row1
				doSort = true
			end
		end
	end
	return sourcetable
end

--[[
	Sort table using specific column index in descending order
]]
function sortTableDescending(sourcetable, columnindex)
	local doSort = true
	while doSort do
		doSort = false
		for n=1, table.getn(sourcetable) - 1, 1 do
			local row1 = sourcetable[n]
			local row2 = sourcetable[n + 1]
			if row1[columnindex] < row2[columnindex] then
				sourcetable[n] = row2
				sourcetable[n + 1] = row1
				doSort = true
			end
		end
	end
	return sourcetable
end

--[[
	Convert a msg so first letter is uppercase, and rest as lower case.
]]
function UCFirst(msg)
	if not msg then
		return ""
	end	

	local f = string.sub(msg, 1, 1)
	local r = string.sub(msg, 2)
	return string.upper(f) .. string.lower(r)
end

--[[
	Validate if a class name is a valid class
	Return true if class is valid
]]
function checkClass(className)
	className = UCFirst(className)
	for n = 1, table.getn(classNames), 1 do
		if classNames[n] == className then
			return true
		end
	end
	return false
end




--  *******************************************************
--
--	Echo Functions
--
--  *******************************************************

--[[
	Echo a message for the local user only.
]]
local function echo(msg)
	if msg and not (msg == "") then
		DEFAULT_CHAT_FRAME:AddMessage(COLOUR_CHAT .. msg .. CHAT_END);
	end
end

--[[
	GuildChat echo
]]
function gcEcho(msg)
	SendChatMessage(msg, OFFICER_CHANNEL)
end

--[[
	GuildChat echo
]]
function guiildEcho(msg)
	SendChatMessage(msg, GUILD_CHANNEL)
end

--[[
	Echo in raid chat (if in raid) or Guild chat (if not)
]]
function rcEcho(msg)
	if isInRaid(true) then
		SendChatMessage(msg, RAID_CHANNEL)
	else
		gcEcho(msg)
	end
end

--[[
	Echo a message for the local user only, including Thaliz "logo"
]]
function GuildDKP_Echo(msg)
	echo(COLOUR_CHAT.."<"..COLOUR_INTRO.."GuildDKP"..COLOUR_CHAT.."> "..msg);
end

function GuildDKP_debug(msg)
	if(tonumber(GDKP_DebugLevel) > 0) then
		echo(msg)
	end
end




--  *******************************************************
--
--	Transaction Functions
--
--  *******************************************************

function logSingleTransaction(description, name, dkp)
	local tidChanges = {}
	tidChanges[1] = { name, dkp }
	logMultipleTransactions(description, tidChanges)
end


function logMultipleTransactions(description, transactions)
	local tid = getNextTransactionID()
	local author = UnitName("Player")
	transactionLog[tid] = { getTimestamp(), tid, author, description, TRANSACTION_STATE_ACTIVE, transactions }

	broadcastTransaction(transactionLog[tid])	
end

--[[
	Broadcast a transaction to other clients
]]
function broadcastTransaction(transaction)
	if isInRaid(true) then
		local timestamp = transaction[1]
		local tid = transaction[2]
		local author = transaction[3]
		local description = transaction[4]
		local transstate = transaction[5]
		local transactions = transaction[6]

		local rec, name, dkp, payload
		for n = 1, table.getn(transactions), 1 do
			rec = transactions[n]
			name = rec[1]
			dkp = rec[2]

			--	TID plus NAME combo is unique.
			payload = timestamp .."/".. tid .."/".. author .."/".. description .."/".. transstate .."/".. name .."/".. dkp
			SendAddonMessage(GUILDDKP_PREFIX, "TX_UPDATE#"..payload.."#", "RAID")
		end
	end
end

function getNextTransactionID()
	currentTransactionID = currentTransactionID + 1
	return currentTransactionID
end

function getTimestamp()
	return date("%H:%M:%S", time())
end

--[[
	Display the next transactions from transactionID <id>, one transaction per line.
	If <id> = 0, then the five last (newest) transactions are shown.
]]
function showTransactionLog(transactionID)
	local transactionCount = table.getn(transactionLog)
	transactionID = tonumber(transactionID)
	
	if (transactionID == 0) then
		transactionID = 1 + transactionCount - TRANSACTION_LIST_SIZE
	end
	if transactionID < 1 then
		transactionID = 1
	end
	
	local lastTransactionID = transactionID + TRANSACTION_LIST_SIZE - 1
	if lastTransactionID > transactionCount then
		lastTransactionID = transactionCount
	end

	for n = transactionID, lastTransactionID, 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		local playerCount = table.getn(tidChanges)

		local stateString = ""
		if state == TRANSACTION_STATE_ROLLEDBACK then
			stateString = ", ***ROLLED BACK***"
		end

		if playerCount == 1 then
			--	Show player details if one person is in transaction list
			local name = tidChanges[1][1]
			local dkp = tidChanges[1][2]			
			GuildDKP_Echo ("[TIME="..timestamp..", TID="..tid..", BY="..author..", CMD="..desc .. stateString.."] : "..name.." --> "..generateColouredDKP(dkp))
		else
			GuildDKP_Echo ("[TIME="..timestamp..", TID="..tid..", BY="..author..", CMD="..desc .. stateString.."] : ("..playerCount.." players affected)")
		end
	end
	GuildDKP_Echo ("Use /GDLogDetails <transaction id> to see transaction details.")
	GuildDKP_Echo ("Use /GDUndo <transaction id> to undo an transaction.")
end

--[[
	Display details for one transaction (takes multiple lines).
]]
function showTransactionDetails(transactionID)
	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		if tonumber(tid) == tonumber(transactionID) then
			GuildDKP_Echo ("[TIME="..timestamp..", TID="..tid..", BY="..author..", CMD="..desc.."]")
			if state == TRANSACTION_STATE_ROLLEDBACK then
				GuildDKP_Echo ("***THIS TRANSACTION WAS ROLLED BACK***")
			end
			
			local sortedList = sortTableAscending(tidChanges, 1)			
			for f = 1, table.getn(sortedList), 1 do
				local r2 = sortedList[f]
				local name = r2[1]
				local dkp = r2[2]
				GuildDKP_Echo ("* "..name.." --> "..generateColouredDKP(dkp))
			end
			
			GuildDKP_Echo ("Use /GDLogPost <TID> to post details to guild chat.")
			GuildDKP_Echo ("Use /GDUndo <TID> to undo an transaction.")
			return
		end
	end
	
	GuildDKP_Echo ("Transaction with TID="..transactionID.." was not found .")
end


--[[
	Display details for one transaction (takes multiple lines) in guild chat.
]]
function showTransactionDetailsInGuildChat(transactionID)
	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		if tonumber(tid) == tonumber(transactionID) then
			rcEcho("[TIME="..timestamp..", TID="..tid..", BY="..author..", CMD="..desc.."] GuildDKP ".. GetAddOnMetadata("GuildDKP", "Version") .." transaction details:")
			if state == TRANSACTION_STATE_ROLLEDBACK then
				rcEcho ("***THIS TRANSACTION WAS ROLLED BACK***")
			end
			
			--	We knows that only GDDecay gives different output per player, so we can check the type before rendering.
			--	For non-GDDecay, we will display 8 players per line = up to 5 lines with players + 1 line of DKP info.

			local totalPlayers = table.getn(tidChanges)
			
			--	GDDecay requires special handling; we can't print the name of all guild members!
			if desc == "GDDecay" then
				local totalDKP = 0
				for f = 1, totalPlayers, 1 do
					local r2 = tidChanges[f]
					local name = r2[1]
					local dkp = r2[2]
					--	Remember that DKP is negative here!
					totalDKP = totalDKP + abs(tonumber(dkp))
				end
				
				rcEcho ("* Total DKP removed: ".. totalDKP)
				rcEcho ("* Players affected: ".. totalPlayers)
				rcEcho ("* Average per player: ".. floor(totalDKP / totalPlayers))
				return
			end
			
			if totalPlayers == 1 then			
				for f = 1, totalPlayers, 1 do
					local r2 = tidChanges[f]
					local name = r2[1]
					local dkp = r2[2]

					rcEcho ("* "..name.." --> "..dkp)
				end
				return
			end


			--	List multiple player data:
			local output = ""
			local outputCount = 0
			local dkpValuePrinted = false
			
			local sortedList = sortTableAscending(tidChanges, 1)			
			for f = 1, totalPlayers, 1 do			
				local r2 = sortedList[f]
				local name = r2[1]
				local dkp = r2[2]
				
				if not dkpValuePrinted then				
					rcEcho ("  DKP per player: "..dkp..", total players affected: ".. totalPlayers)
					dkpValuePrinted = true
				end
				
				if output == "" then
					output = "* "..name
				else
					output = output..", "..name
				end
				
				outputCount = outputCount + 1
				if outputCount >= TRANSACTION_PLAYERS_PER_LINE then
					rcEcho (output)
					output = ""					
					outputCount = 0
				end
			end
			if output then
				rcEcho (output)
			end
			return
		end
	end
	
	GuildDKP_Echo ("Transaction with TID=<"..transactionID.."> was not found.")
end


--[[
	Undo a transaction.
	This must be called using Callback functions.
	Also, offline members bust be shown in order to be able to restore DKP correctly for all.
	The transaction is set in UNDONE state, and the DKP is reverted.
	Only transactions in ACTIVE state can be undone.
]]
function undoTransaction(transactionID)

	if not GetGuildRosterShowOffline() then
		GuildDKP_Echo("Undo cancelled: You need to enable Offline Guild Members in the guild roster first.")
		return
	end

	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		if tonumber(tid) == tonumber(transactionID) then		
			if state == TRANSACTION_STATE_ROLLEDBACK then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is already rolled back.")
				return
			end
			
			transactionLog[tid][5] = TRANSACTION_STATE_ROLLEDBACK
			
			--	Now revert the DKP:
			for f = 1, table.getn(tidChanges), 1 do
				local r2 = tidChanges[f]
				local name = r2[1]
				local dkp = tonumber(r2[2])
				
				applyDKP(name, (-1 * dkp))				
			end
			
			GuildDKP_Echo ("Transaction with TID="..transactionID.." was successfully rolled back.")
			return
		end

	end
	
	GuildDKP_Echo ("Transaction with TID="..transactionID.." was not found.")
end


--[[
	Redo a transaction (cancel transaction rollback)
	This must be called using Callback functions.
	Also, offline members bust be shown in order to be able to restore DKP correctly for all.
	The transaction is set in ACTIVE state, and the DKP is reverted.
	Only transactions in ROLLEDBACK state can be re-done.
]]
function redoTransaction(transactionID)

	if not GetGuildRosterShowOffline() then
		GuildDKP_Echo("Redo cancelled: You need to enable Offline Guild Members in the guild roster first.")
		return
	end

	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		if tonumber(tid) == tonumber(transactionID) then
			if state == TRANSACTION_STATE_ACTIVE then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is already active.")
				return
			end
			
			transactionLog[tid][5] = TRANSACTION_STATE_ACTIVE
			
			--	Now re-apply the DKP:
			for f = 1, table.getn(tidChanges), 1 do
				local r2 = tidChanges[f]
				local name = r2[1]
				local dkp = tonumber(r2[2])
				
				applyDKP(name, dkp)
			end
			
			GuildDKP_Echo ("Transaction with TID="..transactionID.." was successfully reactivated.")
			return
		end

	end
	
	GuildDKP_Echo ("Transaction with TID="..transactionID.." was not found.")
end


--[[
	Add player <name> to the transaction, and remove his dkp.
	Only transactions in ACTIVE state can include players.
	Furthermore GDDecay or empty transactions cannot be included.
]]
function includePlayerInTransaction(transactionID, playername)

	if not GetGuildRosterShowOffline() then
		GuildDKP_Echo("Player include cancelled: You need to enable Offline Guild Members in the guild roster first.")
		return
	end

	playername = UCFirst(playername)

	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		--	Find transaction to include player to:
		if tonumber(tid) == tonumber(transactionID) then
			if state == TRANSACTION_STATE_ROLLEDBACK then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is rolled back - player cannot be included.")
				return
			end
			
			if desc == "GDDecay" then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is a GDDecay transaction - player cannot be included.")
				return
			end			

			local playerCnt = table.getn(tidChanges)
			if playerCnt == 0 then
				GuildDKP_Echo("Player include cancelled: You cannot add a player to an empty transaction.")
				return
			end
			
			for f = 1, playerCnt, 1 do
				local r2 = tidChanges[f]
				local name = r2[1]
				if name and UCFirst(name) == playername then
					GuildDKP_Echo("Player include cancelled: "..playername.." is already in the transaction.")
					return				
				end
			end
					
			local tidData = tidChanges[1]
			local dkp = tidData[2]

			applyDKP(playername, tonumber(dkp))
					
			tidChanges[playerCnt + 1] = { UCFirst(playername), dkp }

			GuildDKP_Echo (playername.." was added to the transaction with TID="..transactionID.." for "..dkp.." DKP.")
			return
		end

	end
	
	GuildDKP_Echo ("Transaction with TID="..transactionID.." was not found.")
end


--[[
	Remove player <name> from the transaction, and reapply his dkp.
	Only transactions in ACTIVE state can exclude players.
	Furthermore GDDecay transactions cannot be excluded.
]]
function excludePlayerInTransaction(transactionID, playername)

	if not GetGuildRosterShowOffline() then
		GuildDKP_Echo("Player exclude cancelled: You need to enable Offline Guild Members in the guild roster first.")
		return
	end

	playername = UCFirst(playername)

	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]
		
		if tonumber(tid) == tonumber(transactionID) then
			if state == TRANSACTION_STATE_ROLLEDBACK then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is rolled back - player cannot be excluded.")
				return
			end
			
			if desc == "GDDecay" then
				GuildDKP_Echo ("Transaction with TID="..transactionID.." is a GDDecay transaction - player cannot be excluded.")
				return
			end			
		
			--	Now find the player to exclude:
			for f = 1, table.getn(tidChanges), 1 do
				local r2 = tidChanges[f]
				local name = r2[1]
				local dkp = tonumber(r2[2])
				
				if name and UCFirst(name) == playername then
					applyDKP(name, (-1 * dkp))					
					
					tidChanges[f] = {}
					rec[6] = packTable(tidChanges)
					transactionLog[n] = rec
					
					GuildDKP_Echo (name.." was removed from transaction with TID="..transactionID..".")
					return
				end				
			end
			
			GuildDKP_Echo (name.." was not found in the transaction with TID="..transactionID..".")
			return
		end
	end
	
	GuildDKP_Echo ("Transaction with TID="..transactionID.." was not found.")
end


--[[
	Synchronize the local transaction log with other clients.
	This is done in a two-step approach:
	- step 1:
		A TX_SYNCINIT is sent to all clients. Each clients now responds
		back (RX_SYNCINIT) with lowest and hignest TID.
		This shows how many transactions each client contains.
	- step 2:
		The client picks the response with most transactions in it,
		and will ask that client for all transactions.
		Note that step 2 will require a delay to allow all clients to
		respond back (a 2 second delay should be fine).

	Transactions are merged into existing transaction log, there is therefore
	no need to delete log fiest.
	This method should be called when GuildDKP is launched, or player enters
	a raid to make sure transactionlog is always updated.
]]
function synchronizeTransactionLog()
	--	This initiates step 1: send a TX_SYNCINIT to all clients.
	--	TODO: Check if we're already requesting SYNC - abort with an error if so.
	
	synchronizationState = 1	-- Step 1: Initialize
	
	SendAddonMessage(GUILDDKP_PREFIX, "TX_SYNCINIT##", "RAID")
	
	--GuildDKP_AddTimer(HandleRXSyncInitDone, 3)	
	AddMimmaTimer(HandleRXSyncInitDone, 3)	
end

function generateColouredDKP(dkp)
	local output = COLOUR_DKP_PLUS
	if tonumber(dkp) < 0 then
		output = COLOUR_DKP_MINUS
	end
	output = output .. dkp .. COLOUR_CHAT
	return output
end




--  *******************************************************
--
--	Communication Functions
--
--  *******************************************************

--[[
	Chat Addon Communication functions.
	<Recipient name> is used when the destination is set to be a specific character;
	usually in responses (RX).
	
	TX_VERSION#<>#<>
		Request client version information
	RX_VERSION#<version number>#<recipient name>
		Response to a version request.
		
	TX_UPDATE#<transaction info>#<>
		Multicast a transaction to other clients.
		
	TX_SYNCINIT#<>#<>
		Request highest transaction id
	RX_SYNCINIT#<max transaction id>#<recipient name>
		Response with highest transaction id

	TX_SYNCTRAC#<>#<recipient name>
		Request synchronization of transactions from selected client

]]


--[[
	Respond to a TX_VERSION command.
	Input:
		msg is the raw message
		sender is the name of the message sender.
	We should whisper this guy back with our current version number.
	We therefore generate a response back (RX) in raid with the syntax:
	GuildDKP:<sender (which is actually the receiver!)>:<version number>
]]
local function HandleTXVersion(message, sender)
	local response = GetAddOnMetadata("GuildDKP", "Version")
	
	SendAddonMessage(GUILDDKP_PREFIX, "RX_VERSION#"..response.."#"..sender, "RAID")
end

--[[
	A version response (RX) was received. The version information is displayed locally.
]]
local function HandleRXVersion(message, sender)
	local out = "".. sender .." is using GuildDKP version ".. message
	GuildDKP_Echo(out)
end


--[[
	TX_UPDATE: A transaction was broadcasted. Add transaction details to transactions list.
]]
local function HandleTXUpdate(message, sender)
	--	Message was from SELF, no need to update transactions since I made them already!
	if (sender == UnitName("player")) then
		return
	end

	local _, _, timestamp, tid, author, description, transstatus, name, dkp = string.find(message, "([^/]*)/([0-9]*)/([^/]*)/([^/]*)/([0-9]*)/([^/]*)/([^/]*)")

	tid = tonumber(tid)

	local transaction = transactionLog[tid]
	if not transaction then
		transaction = { timestamp, tid, author, description, transstatus, {} }
	end
	
	--	List of transaction lines contained in this transaction ("name=dkp" entries)
	local transactions = transaction[6]
	local count = table.getn(transactions)
	transactions[count + 1] = { name, dkp }
	transaction[6] = transactions
	
	transactionLog[tid] = transaction

	-- Make sure to update next transactionid
	if currentTransactionID < tid then
		currentTransactionID = tid
	end

end


--	Clients must return the highest transaction ID they own in RX_SYNCINIT
function HandleTXSyncInit(message, sender)
	--	Message was from SELF, no need to return RX_SYNCINIT
	if (sender == UnitName("player")) then
		return
	end

	syncResults = {}
	SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCINIT#"..currentTransactionID.."#"..sender, "RAID")
end


--Handle RX_SYNCINIT responses from clients
function HandleRXSyncInit(message, sender)
	--	Check we are still in TX_SYNCINIT state
	if not (synchronizationState == 1) then
		return
	end

	local maxTid = tonumber(message)
	local syncIndex = table.getn(syncResults) + 1
	
	syncResults[syncIndex] = { sender, message }
end


--	This is called by the timer when responses are no longer accepted
function HandleRXSyncInitDone()
	synchronizationState = 2
	local maxTid = 0
	local maxName = ""

	for n = 1, table.getn(syncResults), 1 do
		local res = syncResults[n]
		local tid = tonumber(res[2])
		if(tid > maxTid) then
			maxTid = tid
			maxName = res[1]
		end
	end

	--	No transactions was found, nothing to sync.
	if maxTid == 0 then
		synchronizationState = 0
	end

	if maxTid > currentTransactionID then
		currentTransactionID = maxTid
	end

	--	Now request transaction synchronization from selected target
	SendAddonMessage(GUILDDKP_PREFIX, "TX_SYNCTRAC##"..maxName, "RAID")	
end


--	Client is requested to sync transaction log with <sender>
function HandleTXSyncTransaction(message, sender)
	--	Iterate over transactions
	for n = 1, table.getn(transactionLog), 1 do
		local rec = transactionLog[n]
		local timestamp = rec[1]
		local tid = rec[2]
		local author = rec[3]
		local desc = rec[4]
		local state = rec[5]
		local tidChanges = rec[6]

		--	Iterate over transaction lines
		for f = 1, table.getn(tidChanges), 1 do
			local change = tidChanges[f]
			local name = change[1]
			local dkp = change[2]
			
			local response = timestamp.."/"..tid.."/"..author.."/"..desc.."/"..state.."/"..name.."/"..dkp
			
			SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCTRAC#"..response.."#"..sender, "RAID")				
		end
	end
	
	--	Last, send an EOF to signal all transactions were sent.
	SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCTRAC#EOF#"..sender, "RAID")				
end


--	Received a sync'ed transaction - merge this with existing transaction log.
function HandleRXSyncTransaction(message, sender)
	if message == "EOF" then
		synchronizationState = 0
		return
	end

	local _, _, timestamp, tid, author, description, transstatus, name, dkp = string.find(message, "([^/]*)/([0-9]*)/([^/]*)/([^/]*)/([0-9]*)/([^/]*)/([^/]*)")

	tid = tonumber(tid)

	local transaction = transactionLog[tid]
	if not transaction then
		transaction = { timestamp, tid, author, description, transstatus, {} }
	end

	local transactions = transaction[6]
	local tracCount = table.getn(transactions)

	--	Check if this transaction line does already exist in transaction
	for f = 1, tracCount, 1 do
		local trac = transactions[f]
		local currentName = trac[1]
		local currentDkp = trac[2]

		--	This entry already exists - no need to process further.
		if currentName == name then
			return
		end
	end

	--	If we end here, then the transaction does not exist in our transaction log.
	--	Create entry:
	transactions[tracCount + 1] = { name, dkp }
	transaction[6] = transactions
	transactionLog[tid] = transaction
end




--  *******************************************************
--
--	Job Queue Functions
--
--  *******************************************************

function AddJob( method, arg1, arg2 )
	jobQueue[table.getn(jobQueue) + 1] = { method, arg1, arg2 }
end

function getNextJob()
	local job
	local cnt = table.getn(jobQueue)
	
	if cnt > 0 then
		job = jobQueue[1]
		for n=2,cnt,1 do
			jobQueue[n-1] = jobQueue[n]			
		end
		jobQueue[cnt] = nil
	end

	return job
end




--  *******************************************************
--
--	Context menu functions
--
--  *******************************************************

USER_DROPDOWNBUTTONS = {};

function GuildDKP_addDropDownMenuButton(uid, dropdown, index, title, usable, onClick, hint)
	tinsert(UnitPopupMenus[dropdown],index,uid);
	if(hint) then
		UnitPopupButtons[uid] = { text = title, dist = 0, tooltip = hint};
	else
		UnitPopupButtons[uid] = { text = title, dist = 0 };
	end
	
	USER_DROPDOWNBUTTONS[uid] = { func = onClick, enabled = usable };
end


local GuildDKP_UIDropDownMenu_AddButton = UIDropDownMenu_AddButton;
UIDropDownMenu_AddButton = function(info, level)
	if(USER_DROPDOWNBUTTONS[info.value]) then
		local dropdownFrame = getglobal(UIDROPDOWNMENU_INIT_MENU);
		info.func = USER_DROPDOWNBUTTONS[info.value].func;
	end;
	GuildDKP_UIDropDownMenu_AddButton(info,level);
end;


function GuildDKP_AddDKPFromMenu()
	local frame = getglobal(UIDROPDOWNMENU_OPEN_MENU);

	if isInRaid(false) then
		StaticPopupDialogs["DKP_POPUP"] = {
			text = string.format("Add DKP to %s:", UnitName(frame.unit)),
			hasEditBox = true,
			hideOnEscape = true,
			whileDead = true,
			button1 = "Okay",
			button2 = "Cancel",
			timeout = 0,
			maxLetters = 6,
			OnShow = function()	
				local c = getglobal(this:GetName().."EditBox");
				c:SetText("");
			end,
			EditBoxOnEnterPressed = function()
				this:GetParent():Hide();
				GuildDKP_DoAddDKPFromMenu(UnitName(frame.unit), this:GetText());
			end,
			OnAccept = function(self, data)
				local c = getglobal(this:GetParent():GetName().."EditBox");		
				GuildDKP_DoAddDKPFromMenu(UnitName(frame.unit), c:GetText());
			end
		}
		StaticPopup_Show("DKP_POPUP");
	end
end

function GuildDKP_DoAddDKPFromMenu(name, dkp)
	if isInRaid(false) and canWriteNotes() then
		if dkp and name and tonumber(dkp) then
			AddJob( GDPlus_callback, name, dkp )
			requestUpdateRoster()
		else
			GuildDKP_Echo(string.format("%s is not a valid number", dkp));
		end
	end
end

function GuildDKP_SubtractDKPFromMenu()
	local frame = getglobal(UIDROPDOWNMENU_OPEN_MENU);

	if isInRaid(false) then
		StaticPopupDialogs["DKP_POPUP"] = {
			text = string.format("Subtract DKP from %s:", UnitName(frame.unit)),
			hasEditBox = true,
			hideOnEscape = true,
			whileDead = true,
			button1 = "Okay",
			button2 = "Cancel",
			timeout = 0,
			maxLetters = 6,
			OnShow = function()	
				local c = getglobal(this:GetName().."EditBox");
				c:SetText("");
			end,
			EditBoxOnEnterPressed = function()
				this:GetParent():Hide();
				GuildDKP_DoSubtractDKPFromMenu(UnitName(frame.unit), this:GetText());
			end,
			OnAccept = function(self, data)
				local c = getglobal(this:GetParent():GetName().."EditBox");
				GuildDKP_DoSubtractDKPFromMenu(UnitName(frame.unit), c:GetText());
			end
		}
		StaticPopup_Show("DKP_POPUP");
	end
end

function GuildDKP_DoSubtractDKPFromMenu(name, dkp)
	if isInRaid(false) and canWriteNotes() then
		if dkp and name and tonumber(dkp) then
			AddJob( GDMinus_callback, name, dkp )
			requestUpdateRoster()
		else
			GuildDKP_Echo(string.format("%s is not a valid number", dkp));
		end
	end
end

function GuildDKP_SubtractPercentFromMenu()
	local frame = getglobal(UIDROPDOWNMENU_OPEN_MENU);
	
	if isInRaid(false) then
		StaticPopupDialogs["DKP_POPUP"] = {
			text = string.format("Subtract PERCENT from %s:", UnitName(frame.unit)),
			hasEditBox = true,
			hideOnEscape = true,
			whileDead = true,
			button1 = "Okay",
			button2 = "Cancel",
			timeout = 0,
			maxLetters = 2,
			OnShow = function()	
				local c = getglobal(this:GetName().."EditBox");
				c:SetText("");
			end,
			EditBoxOnEnterPressed = function()
				this:GetParent():Hide();
				GuildDKP_DoSubtractPercentFromMenu(UnitName(frame.unit), this:GetText());
			end,
			OnAccept = function(self, data)
				local c = getglobal(this:GetParent():GetName().."EditBox");
				GuildDKP_DoSubtractPercentFromMenu(UnitName(frame.unit), c:GetText());
			end
		}
		StaticPopup_Show("DKP_POPUP");
	end
end

function GuildDKP_DoSubtractPercentFromMenu(name, pct)
	if isInRaid(false) and canWriteNotes() then
		if pct and name and tonumber(pct) then
			AddJob( GDMinusPercent_callback, name, pct )
			requestUpdateRoster()
		else
			GuildDKP_Echo(string.format("%s is not a valid number", pct));
		end
	end
end



--  *******************************************************
--
--	Event Handlers
--
--  *******************************************************

function GuildDKP_OnLoad()
	GuildDKP_Echo("GuildDKP version " .. GetAddOnMetadata("GuildDKP", "Version") .. " by ".. GetAddOnMetadata("GuildDKP", "Author"))

    this:RegisterEvent("GUILD_ROSTER_UPDATE")
    this:RegisterEvent("CHAT_MSG_ADDON")
    this:RegisterEvent("RAID_ROSTER_UPDATE")
    
    -- If GuildDKP_addDropDownMenuButton could just accept functions and not a boolean - grrrr!
    -- Now we have to either ENABLE or DISABLE buttons all time, not only when in raid.
    local GuildDKP_ValidForMenu = true;
    
	GuildDKP_addDropDownMenuButton("PercentDKPParty", "PARTY", 1, "Penalty DKP", GuildDKP_ValidForMenu, GuildDKP_SubtractPercentFromMenu);
	GuildDKP_addDropDownMenuButton("PlusDKPParty", "PARTY", 1, "Add DKP", GuildDKP_ValidForMenu, GuildDKP_AddDKPFromMenu);
	GuildDKP_addDropDownMenuButton("MinusDKPParty", "PARTY", 1, "Subtract DKP", GuildDKP_ValidForMenu, GuildDKP_SubtractDKPFromMenu);

	--	This line seperates DKP options with remaining options.
	--	Next option is REMOVE (from raid), we should not click this by accident!
	GuildDKP_addDropDownMenuButton("DKPSplitter", "RAID", 1, "--------------------", GuildDKP_ValidForMenu, nil);
	GuildDKP_addDropDownMenuButton("PercentDKPRaid", "RAID", 1, "Penalty DKP", GuildDKP_ValidForMenu, GuildDKP_SubtractPercentFromMenu);
	GuildDKP_addDropDownMenuButton("PlusDKPRaid", "RAID", 1, "Add DKP", GuildDKP_ValidForMenu, GuildDKP_AddDKPFromMenu);
	GuildDKP_addDropDownMenuButton("MinusDKPRaid", "RAID", 1, "Subtract DKP", GuildDKP_ValidForMenu, GuildDKP_SubtractDKPFromMenu);

	SetGuildRosterShowOffline(true)
	requestUpdateRoster()
	
	if isInRaid(true) then	
		synchronizeTransactionLog()
	end
end

function GuildDKP_OnEvent(event)
	if (event == "CHAT_MSG_ADDON") then
		OnChatMsgAddon(event, arg1, arg2, arg3, arg4, arg5)
	elseif (event == "GUILD_ROSTER_UPDATE") then
		OnGuildRosterUpdate()
	elseif (event == "RAID_ROSTER_UPDATE") then
		OnRaidRosterUpdate(event, arg1, arg2, arg3, arg4, arg5)
	end
end

function OnGuildRosterUpdate()
	handleGuildRosterUpdate()
end

function OnRaidRosterUpdate(event, arg1, arg2, arg3, arg4, arg5)
	if isInRaid(true) then
		synchronizeTransactionLog()
	else
		transactionLog = {}
	end
end
 
function OnChatMsgAddon(event, prefix, msg, channel, sender)
	if prefix == GUILDDKP_PREFIX then
		--echo(msg)
	
		--	Split incoming message in Command, Payload (message) and Recipient
		local _, _, cmd, message, recipient = string.find(msg, "([^#]*)#([^#]*)#([^#]*)")

		if not cmd then
			return	-- cmd is mandatory, remaining parameters are optionel.
		end

		--	Ignore message if it is not for me. Receipient can be blank, which means it is for everyone.
		if not (recipient == "") then
			if not (recipient == UnitName("player")) then
				return
			end
		end
		
		if not message then
			message = ""
		end
	
		if cmd == "TX_VERSION" then
			HandleTXVersion(message, sender)
		elseif cmd == "RX_VERSION" then
			HandleRXVersion(message, sender)
		elseif cmd == "TX_UPDATE" then
			HandleTXUpdate(message, sender)
		elseif cmd == "TX_SYNCINIT" then
			HandleTXSyncInit(message, sender)
		elseif cmd == "RX_SYNCINIT" then
			HandleRXSyncInit(message, sender)
		elseif cmd == "TX_SYNCTRAC" then
			HandleTXSyncTransaction(message, sender)
		elseif cmd == "RX_SYNCTRAC" then
			HandleRXSyncTransaction(message, sender)
		else
			GuildDKP_Echo("Unknown command, raw msg="..msg)
		end
	end
end


