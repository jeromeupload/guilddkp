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
-- Min/Max amount of dkp
local maxDKP = 600
local minDKP = 0

local RAID_CHANNEL = "RAID"
local GUILD_CHANNEL = "GUILD"
local OFFICER_CHANNEL = "OFFICER"
local CHAT_END = "|r"
local COLOUR_CHAT = "|c8040A0F8"
local COLOUR_INTRO  = "|c8000F0F0"
local GUILDDKP_PREFIX = "GuildDKPv1"

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
local classNames = { "Druid", "Hunter", "Mage", "Warrior", "Warlock", "Priest", "Rogue", "Shaman" }
--	Sync.state: 0=idle, 1=initializing, 2=synchronizing
local synchronizationState = 0
--	Hold RX_SYNCINIT responses when querying for a client to sync.
local syncResults = {}
-- Create the dropdown, and configure its appearance
local dropDown = CreateFrame("FRAME", "GuildDKPDrop", UIParent, "UIDropDownMenuTemplate")

--[[
	UI additions
]]
SLASH_GUILDDKP_SHOW1 = "/gdshow"
SlashCmdList["GUILDDKP_SHOW"] = function(msg)
	-- Get all guildies whom are not alts
	local memberCount = GetNumGuildMembers()
	local classMembers = {
		["Druid"] = {},
		["Hunter"] = {},
		["Mage"] = {},
		["Warrior"] = {},
		["Warlock"] = {},
		["Priest"] = {},
		["Rogue"] = {},
		["Shaman"] = {}
	}
	local playerDKP = {}
	for n=1,memberCount,1 do
		local player, rank, _, _, class, _, publicNote, officerNote = GetGuildRosterInfo(n)
        local name = ""
        local realm = ""
        name, realm = player:match("([^,]+)%-([^,]+)")
		local _, _, dkp = string.find(officerNote, "<(-?%d*)>")

		if rank ~= "Alt" then
			-- We have now verified that the players in not an alt, so we
			-- insert the player and DKP amoun into the dictionary in the corresponding class key
			table.insert(classMembers[class], name)
			playerDKP[name] = dkp
		end
	end
	dropDown:Show()
	dropDown:SetPoint("CENTER")
	dropDown:SetMovable(true)
	dropDown:EnableMouse(true)
	dropDown:RegisterForDrag("LeftButton")
	dropDown:SetScript("OnDragStart", dropDown.StartMoving)
	dropDown:SetScript("OnDragStop", dropDown.StopMovingOrSizing)
	UIDropDownMenu_SetWidth(dropDown, 200)
	UIDropDownMenu_SetText(dropDown, "GuildDKP")

	-- Create and bind the initialization function to the dropdown menu
	UIDropDownMenu_Initialize(dropDown, function(self, level, menuList)
		local info = UIDropDownMenu_CreateInfo()
		if (level or 1) == 1 then
			for index,item in ipairs(classNames) do
				info.text, info.menuList, info.hasArrow, info.notCheckable = item, item, true, true
				UIDropDownMenu_AddButton(info)
			end
		elseif (level or 2) == 2 then
			for key,val in pairs(classMembers) do
				for index,name in ipairs(val) do
					if key == menuList then
						info.text, info.menuList, info.hasArrow, info.notCheckable = name, name, true, true
						UIDropDownMenu_AddButton(info, level)
					end
				end
			end
		elseif (level or 3) == 3 then
			for key,val in pairs(playerDKP) do
				if key == menuList then
					info.text, info.menuList, info.notCheckable = string.format("%s DKP", val), val, true
					UIDropDownMenu_AddButton(info, level)
				end
			end
		end
	end)
end

SLASH_GUILDDKP_HIDE1 = "/gdhide"
SlashCmdList["GUILDDKP_HIDE"] = function(msg)
	dropDown:Hide()
end

--[[
	Display DKP for a specific user, or current user if no playername was given.
	Syntax: /gddkp [<player>]
]]
SLASH_GUILDDKP_STATUS_DKP1 = "/gddkp"
SLASH_GUILDDKP_STATUS_DKP2 = "/dkp"
SlashCmdList["GUILDDKP_STATUS_DKP"] = function(msg)
	local _, _, name = string.find(msg, "(%S*).*")
	if not name or name == "" then
		name = UnitName("player")
	end
	displayDKPForGuildedPlayer(UCFirst(name))
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

	displayDKPForGuildedClass(classname)
	requestUpdateRoster()
end

--[[
	Add DKP to a specific char and announce in /RW
	Syntax: /gdadd <player> <dkp value>
]]
SLASH_GUILDDKP_PLUS_DKP1 = "/gdadd"
SLASH_GUILDDKP_PLUS_DKP2 = "/gdp"
SlashCmdList["GUILDDKP_PLUS_DKP"] = function(msg)
	local _, _, name, dkp = string.find(msg, "(%S*)%s*(%d*).*")
	if isInRaid() and CanEditOfficerNote() then
		if dkp and name and tonumber(dkp) then
			local res = applyDKP(UCFirst(name), dkp)
			if res then
				SendChatMessage(string.format("%s has been awarded %s DKP", UCFirst(name), dkp), "RAID_WARNING")
				requestUpdateRoster()
			end
		else
			GuildDKP_Echo("Syntax: /gdadd <name> <dkp value>")
		end
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

	if isInRaid() and CanEditOfficerNote() then
		if dkp and name and tonumber(dkp) then
			local res = applyDKP(UCFirst(name), (-1 * dkp))
			if res then
				SendChatMessage(string.format("%s DKP has been subtracted from %s", dkp, UCFirst(name)), "RAID_WARNING")
				requestUpdateRoster()
			end
		else
			GuildDKP_Echo("Syntax: /gdminus <name> <dkp value>")
		end
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

	if isInRaid() and CanEditOfficerNote() then
		if dkp and tonumber(dkp) then
			addRaidDKP(dkp, "GDAddRaid")
			SendChatMessage(string.format("%s DKP has been added to all players in raid", dkp), "RAID_WARNING")
			requestUpdateRoster()
		else
			GuildDKP_Echo("Syntax: /gdaddraid <dkp>")
		end
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
		C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "TX_VERSION##", "RAID")
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
	GuildDKP_Echo("/gdversion --  Request version information (if any) for all players in raid.")
	GuildDKP_Echo("")
	GuildDKP_Echo("DKP control:")
	GuildDKP_Echo("/gdadd <player> <amount>  --  Add <amount> DKP to <player> and announce in raid.")
	GuildDKP_Echo("/gdminus <player> <amount>  --  Subtract <amount> DKP from <player> and announce in raid.")
	GuildDKP_Echo("/gdaddraid <amount>  --  Add <amount> DKP to all players in the raid.")
	GuildDKP_Echo("")
	GuildDKP_Echo("UI:")
	GuildDKP_Echo("/gdshow   --  Display GuildDKP UI.")
	GuildDKP_Echo("/gdhide   --  Hide GuildDKP UI.")
	GuildDKP_Echo("")
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
	local playerCount = GetNumGroupMembers()
	if playerCount then
		for n=1,playerCount,1 do
			local name, _, _, _, _, _, _, _, _, _, _ = GetRaidRosterInfo(n)
			applyDKP(name, dkp)
		end
	end
end

--[[
	Apply DKP to a specific player.
	Returns FALSE if DKP could not be applied.
]]
function applyDKP(receiver, dkpValue)
	local memberCount = GetNumGuildMembers()

	for n=1,memberCount,1 do
		local player, rank, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(n)
        local name = ""
        local realm = ""
        name, realm = player:match("([^,]+)%-([^,]+)")

		local note = officerNote
		if name == receiver then
			local _, _, dkp = string.find(note, "<(-?%d*)>")

			if rank == "Alt" then
				GuildDKP_Echo(string.format("%s is of rank %s and will not receive DKP", name, rank))
				return false
			end

			if dkp and tonumber(dkp) then
				if tonumber(dkp) <= maxDKP and (tonumber(dkp) + tonumber(dkpValue)) <= maxDKP then
					if (tonumber(dkp) + dkpValue) >= minDKP then
						dkp = (1 * dkp) + dkpValue
						note = string.gsub(note, "<(-?%d*)>", createDkpString(dkp), 1)
						if tonumber(dkpValue) > 0 then
							SendChatMessage(string.format("You have been rewarded with %s DKP", dkpValue), "WHISPER", "Common", name)
						else
							SendChatMessage(string.format("%s DKP has been subtracted you", (-1 * tonumber(dkpValue))), "WHISPER", "Common", name)
						end
					else
						GuildDKP_Echo(name.." will get below 0 DKP. Aborting.")
						return false
					end
				else

					if tonumber(dkp) ~= maxDKP then
						note = string.gsub(note, "<(-?%d*)>", createDkpString(600), 1)
						SendChatMessage("Your DKP is now at 600.", "WHISPER", "Common", name)
					else
						GuildDKP_Echo(name.." will exceed "..maxDKP.." DKP. Aborting.")
						return false
					end
				end
			else
				dkp = dkpValue
				note = note..createDkpString(dkp)
			end
			GuildRosterSetOfficerNote(n, note)
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
	Display DKP amount for a specific player (locally) in the guild
]]
function displayDKPForGuildedPlayer(receiver)
	local player, dkp, class = getGuildPlayer(receiver)
	if player then
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
		local player, _, _, _, class, _, publicNote, officerNote = GetGuildRosterInfo(n)
        local name = ""
        local realm = ""
        name, realm = player:match("([^,]+)%-([^,]+)")
		local _, _, dkp = string.find(officerNote, "<(-?%d*)>")

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
	(/gdclass and /gddkp)
]]
function refreshGuildRoster()
	local memberCount = GetNumGuildMembers()

	guildRoster = {}

	local note
	local index = 1	
	for m=1,memberCount,1 do
		local player, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(m)
        local name = ""
        local realm = ""
        name, realm = player:match("([^,]+)%-([^,]+)")

		if useOfficerNotes then		
			note = officerNote
		else
			note = publicNote
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
	local playerCount = GetNumGroupMembers()
	
	if playerCount then
		--	name, rank, rankIndex, level, class, zone, note, officernote
		local members = {}
		local memberCount = GetNumGuildMembers()

		--	Loop over all _online_ players
		local index = 0
		for m=1,memberCount,1 do
			local player, _, _, _, class, _, publicNote, officerNote, online = GetGuildRosterInfo(m)
            local name = ""
            local realm = ""
            name, realm = player:match("([^,]+)%-([^,]+)")

			index = index + 1
			if useOfficerNotes then
				members[index] = { name, officerNote, class, online }
			else
				members[index] = { name, officerNote, class, online }
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
	Return the amount of DKP a specific player in the guild currently has.
	Input: player name
	Output: DKP value, or nil if player was not found.
]]
function getGuildPlayer(receiver)
	for n=1, GetNumGuildMembers(),1 do
		local player, _, _, _, class, _, publicNote, officerNote, online = GetGuildRosterInfo(n)
		local _, _, dkp = string.find(officerNote, "<(-?%d*)>")
		local name = ""
		local realm = ""
		name, realm = player:match("([^,]+)%-([^,]+)")
		
		if name == receiver then
			return name, dkp, class
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
		local result = canReadOfficerNotes()
	else
		local result = canReadGuildNotes()
	end
	return result
end

function canWriteNotes()
	if useOfficerNotes then
		local result = canWriteOfficerNotes()
	else
		local result = canWriteGuildNotes()
	end
	return result
end

function canReadGuildNotes()
	return true
end

function canReadOfficerNotes()
	return true
end

function canWriteGuildNotes()
	local result = canReadGuildNotes() and CanEditPublicNote()
	if not result then
		GuildDKP_Echo("Sorry, but you do not have access to write guild notes.")
	end
	return result	
end

function canWriteOfficerNotes()
	--local result = CanViewOfficerNote() and CanEditOfficerNote()
	--if not result then
	--	GuildDKP_Echo("Sorry, but you do not have access to write officer notes.")
	--end
	return true
end

function isInRaid(silentMode)
	local result = ( GetNumGroupMembers() > 0 )
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
	
	C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "RX_VERSION#"..response.."#"..sender, "RAID")
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
	C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCINIT#"..currentTransactionID.."#"..sender, "RAID")
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
	C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "TX_SYNCTRAC##"..maxName, "RAID")	
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
			
			C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCTRAC#"..response.."#"..sender, "RAID")				
		end
	end
	
	--	Last, send an EOF to signal all transactions were sent.
	C_ChatInfo.SendAddonMessage(GUILDDKP_PREFIX, "RX_SYNCTRAC#EOF#"..sender, "RAID")				
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
--	Event Handlers
--
--  *******************************************************

function GuildDKP_OnLoad(self)
	GuildDKP_Echo("GuildDKP version " .. GetAddOnMetadata("GuildDKP", "Version") .. " by ".. GetAddOnMetadata("GuildDKP", "Author"))

    self:RegisterEvent("GUILD_ROSTER_UPDATE") 
    self:RegisterEvent("CHAT_MSG_ADDON")
    self:RegisterEvent("RAID_ROSTER_UPDATE")

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

		--	Ignore message if it is not for me. Recipient can be blank, which means it is for everyone.
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