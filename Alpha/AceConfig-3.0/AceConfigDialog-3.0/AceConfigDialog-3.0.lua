--[[
AceConfigDialog-3.0

]]

local MAJOR, MINOR = "AceConfigDialog-3.0", 0
local lib = LibStub:NewLibrary(MAJOR, MINOR)

if not lib then return end

lib.OpenFrames = lib.OpenFrames or {}
lib.Status = lib.Status or {}


local gui = LibStub("AceGUI-3.0")
local reg = LibStub("AceConfigRegistry-3.0")
local con = LibStub("AceConsole-3.0", true)
--[[
Group Types
  Tree 	- All Descendant Groups will all become nodes on the tree, direct child options will appear above the tree
  		- Descendant Groups with inline=true and thier children will not become nodes
  		
  Tab	- Direct Child Groups will become tabs, direct child options will appear above the tab control
  		- Grandchild groups will default to inline unless specified otherwise
  
  Select- Same as Tab but with entries in a dropdown rather than tabs
  
  
  Inline Groups
  	- Will not become nodes of a select group, they will be effectivly part of thier parent group seperated by a border
  	- If declared on a direct child of a root node of a select group, they will appear above the group container control
  	- When a group is displayed inline, all descendants will also be inline members of the group

]]

-- Recycling functions
local new, del
--local newcount, delcount,createdcount = 0,0,0
do
	local pool = setmetatable({},{__mode='k'})
	function new()
		--newcount = newcount + 1
		local t = next(pool)
		if t then
			pool[t] = nil
			return t
		else
			--createdcount = createdcount + 1
			return {}
		end
	end
	function copy(t)
		local c = new()
		for k, v in pairs(t) do
			c[k] = v
		end
		return c
	end
	function del(t)
		--delcount = delcount + 1
		for k in pairs(t) do
			t[k] = nil
		end	
		pool[t] = true
	end
end

-- picks the first non-nil value and returns it
local function pickfirstset(...)	
  for i=1,select("#",...) do
    if select(i,...)~=nil then
      return select(i,...)
    end
  end
end

local function compareOptions(a,b)
	if not a then
		return true
	end
	if not b then
		return false
	end
	local OrderA, OrderB = a.order or 100, b.order or 100
	if OrderA == OrderB then
		local NameA = a.guiName or a.name or ""
		local NameB = b.guiName or b.name or ""
		return NameA:upper() < NameB:upper()
	end
	if OrderA < 0 then
		if OrderB > 0 then
			return false
		end
	else
		if OrderB < 0 then
			return true
		end
	end
	return OrderA < OrderB
end

--gets an option from a given group, checking plugins
local function GetSubOption(group, key)
	if group.plugins then
		for plugin, t in pairs(group.plugins) do
			if t[key] then
				return t[key]
			end
		end		
	end
	
	return group.args[key]
end

--builds 2 tables out of an options group
-- feedkeys, a mapping from table to original key
-- feedtemp, a sorted table of the sub groups
local function BuildSortedOptionsTable(group, feedkeys, feedtmp)
	local keys = new()

	if group.plugins then
		for plugin, t in pairs(group.plugins) do
			for k, v in pairs(t) do
				if not keys[k] then
					tinsert(feedtmp, v)
					feedkeys[v] = k
					keys[k] = true
				end
			end
		end
	end
	
	for k, v in pairs(group.args) do
		if not keys[k] then
			tinsert(feedtmp, v)
			feedkeys[v] = k
			keys[k] = true
		end
	end

	table.sort(feedtmp, compareOptions)
	
	del(keys)
end

local function DelTree(tree)
	if tree.children then
		for i, v in ipairs(tree.children) do
			DelTree(v)
			del(v)
		end
		del(tree.children)
	end
end

local function CleanUserData(widget, event)
	local user = widget.userdata

	if user.path then
		del(user.path)
	end	
	
	if widget.type == "TreeGroup" then
		local tree = widget.tree
		if tree then
			for i, v in ipairs(tree) do
				DelTree(v)
				del(v)
			end
			del(tree)
			widget.tree = nil
		end
	end
	
	if widget.type == "TabGroup" then
		del(widget.tablist)
		del(widget.text)
		widget.tablist = nil
		widget.text = nil
	end
end

--[[
	Gets a status table for the given appname and options path
]]
function lib:GetStatusTable(appName, path)
	local status = self.Status

	if not status[appName] then
		status[appName] = {}
		status[appName].status = {}
		status[appName].children = {}
	end
	
	status = status[appName]

	if path then
		for i, v in ipairs(path) do
			if not status.children[v] then
				status.children[v] = {}
				status.children[v].status = {}
				status.children[v].children = {}
			end
			status = status.children[v]
		end
	end
	
	return status.status
end

local function OptionOnMouseOver(widget, event)
	--show a tooltip/set the status bar to the desc text
	widget.userdata.rootframe:SetStatusText(widget.userdata.option.desc)
end
	
local function GetFuncName(option)
	local type = option.type
	if type == 'execute' then
		return 'func'
	else
		return 'set'
	end	
end

local function confirmPopup(message, func, info, ...)
	if not StaticPopupDialogs["ACECONFIGDIALOG30_CONFIRM_DIALOG"] then
		StaticPopupDialogs["ACECONFIGDIALOG30_CONFIRM_DIALOG"] = {}
	end
	local t = StaticPopupDialogs["ACECONFIGDIALOG30_CONFIRM_DIALOG"]
	for k in pairs(t) do
		t[k] = nil
	end
	t.text = message
	t.button1 = ACCEPT
	t.button2 = CANCEL
	t.OnAccept = function()
		func(info, unpack(t))
		del(info)
	end
	t.OnCancel = function()
		del(info)
	end
	for i = 1, select('#', ...) do
		t[i] = select(i, ...) or false
	end
	t.timeout = 0
	t.whileDead = 1
	t.hideOnEscape = 1

	StaticPopup_Show("ACECONFIGDIALOG30_CONFIRM_DIALOG")
end

local function ActivateControl(widget, event, ...)
	--This function will call the set / execute handler for the widget
	--widget.userdata contains the needed info
	local user = widget.userdata
	local option = user.option
	local options = user.options
	local path = user.path
	local info = new()
	
	local func
	local group = options
	local funcname = GetFuncName(option)
	local handler
	
	--build the info table containing the path
	-- pick up functions while traversing the tree
	if group[funcname] ~= nil then
		func =  group[funcname]
	end
	handler = group.handler or handler
		
	for i, v in ipairs(path) do
		group = GetSubOption(group, v)
		info[i] = v
		if group[funcname] ~= nil then
			func =  group[funcname]
		end
		handler = group.handler or handler
	end

	info.options = options
	info[0] = user.appName
	info.arg = option.arg
	
	local confirm = option.confirm
	local confirmText = option.confirmText
	--call confirm func/method
	if type(confirm) == "string" then
		if handler and handler[confirm] then
			confirm = handler[confirm](handler, info)
			if type(confirm) == "string" then
				confirmText = confirm
				confirm = true
			end
		else
			error("Method doesn't exist in handler")
		end
	elseif type(confirm) == "function" then
		confirm = confirm(info)
		if type(confirm) == "string" then
			confirmText = confirm
			confirm = true
		end
	end
	
	--confirm if needed
	if type(confirm) == "boolean" then
		if confirm then
			if not confirmText then
				confirmText = option.name
				if option.desc then
					confirmText = confirmText.." - "..option.desc
				end
			end
				
			if type(func) == "string" then
				if handler and handler[func] then
					confirmPopup(confirmText, handler[func], handler, info, ...)
				else
					error("Method doesn't exist in handler")
				end
			elseif type(func) == "function" then
				confirmPopup(confirmText, func, info, ...)
			end
			--func will be called and info deleted when the confirm dialog is responded to
			return
		end
	end
	
	--call the function 
	if type(func) == "string" then
		if handler and handler[func] then
			handler[func](handler, info, ...)
		else
			error("Method doesn't exist in handler")
		end
	elseif type(func) == "function" then
		func(info, ...)
	end	
	
	del(info)
	
	--full refresh of the frame
	lib:Open(user.appName)
end


local function ActivateMultiControl(widget, event, ...)
	ActivateControl(widget, event, widget.userdata.value, ...)
end


local function FrameOnClose(widget, event) 
	local appName = widget.userdata.appName
	lib.OpenFrames[appName] = nil
	gui:Release(widget)
end

local function CheckOptionHidden(option, options, path, appName)
	--check for a specific boolean option
	local hidden = pickfirstset(option.dialogHidden,option.guiHidden)
	if hidden ~= nil then
		return hidden
	end
	
	hidden = option.hidden
	if type(hidden) == "boolean" then
		return hidden
	end

	local info = new()
	
	local group = options
	local handler
	
	for i, option in ipairs(path) do
		group = GetSubOption(group, option)
		info[i] = option
		handler = group.handler or handler
	end
	
	info.options = options
	info[0] = appName
	info.arg = option.arg
	
	if type(hidden) == "string" then
		if handler and handler[hidden] then
			hidden = handler[hidden](handler, info)
		else
			error("Method doesn't exist in handler")
		end
	elseif type(hidden) == "function" then
		hidden = hidden(info)
	end

	del(info)
	
	return hidden
end

local function CheckOptionDisabled(option, options, path, appName)
	--check for a specific boolean option
	local disabled = pickfirstset(option.dialogDisabled,option.guiDisabled)
	if disabled ~= nil then
		return disabled
	end
	
	disabled = option.disabled
	if type(disabled) == "boolean" then
		return disabled
	end

	local info = new()
	
	local group = options
	local handler
	
	for i, option in ipairs(path) do
		group = GetSubOption(group, option)
		info[i] = option
		handler = group.handler or handler
	end
	
	info.options = options
	info[0] = appName
	info.arg = option.arg
	
	if type(disabled) == "string" then
		if handler and handler[disabled] then
			disabled = handler[disabled](handler, info)
		else
			error("Method doesn't exist in handler")
		end
	elseif type(disabled) == "function" then
		disabled = disabled(info)
	end

	del(info)
	
	return disabled
end

local function CallOptionsFunction(funcname ,option, options, path, appName, ...)
	local info = new()
	
	local func
	local group = options
	local handler
	
	--build the info table containing the path
	-- pick up functions while traversing the tree
	if group[funcname] ~= nil then
		func = group[funcname]
	end
	handler = group.handler or handler
		
	for i, v in ipairs(path) do
		group = GetSubOption(group, v)
		info[i] = v
		if group[funcname] ~= nil then
			func =  group[funcname]
		end
		handler = group.handler or handler
	end

	info.options = options
	info[0] = appName
	info.arg = option.arg

	local a, b, c ,d
	if type(func) == "string" then
		if handler and handler[func] then
			a,b,c,d = handler[func](handler, info, ...)
		else
			error("Method doesn't exist in handler")
		end
	elseif type(func) == "function" then
		a,b,c,d = func(info, ...)
	end
	del(info)
	return a,b,c,d
end

local function BuildTabs(group, options, path, appName)
	local tabs = new()
	local text = new()
	local feedkeys = new()
	local feedtmp = new()

	BuildSortedOptionsTable(group, feedkeys, feedtmp)

	for i, v in ipairs(feedtmp) do
		local k = feedkeys[v]
		if v.type == "group" then
			local inline = pickfirstset(v.dialogInline,v.guiInline,v.inline, false)
			local hidden = CheckOptionHidden(v, options, path, appName)
			if not inline and not hidden then
				tinsert(tabs, k)
				text[k] = v.name
			end
		end
	end
	
	del(feedkeys)
	del(feedtmp)
	
	return tabs, text
end

local function BuildSubTree(group, tree, options, path, appName)
	local feedkeys = new()
	local feedtmp = new()

	BuildSortedOptionsTable(group, feedkeys, feedtmp)

	for i, v in ipairs(feedtmp) do
		local k = feedkeys[v]
		if v.type == "group" then
			local inline = pickfirstset(v.dialogInline,v.guiInline,v.inline, false)
			local hidden = CheckOptionHidden(v, options, path, appName)
			if not inline and not hidden then
				local entry = new()
				entry.value = k
				entry.text = v.name
				if not tree.children then tree.children = new() end
				tinsert(tree.children,entry)
				if (v.childGroups or "tree") == "tree" then
					BuildSubTree(v,entry, options, path, appName)
				end
			end
		end
	end
	
	del(feedkeys)
	del(feedtmp)
end

local function BuildTree(group, options, path, appName)
	local tree = new()
	local feedkeys = new()
	local feedtmp = new()
	
	BuildSortedOptionsTable(group, feedkeys, feedtmp)

	for i, v in ipairs(feedtmp) do
		local k = feedkeys[v]
		if v.type == "group" then
			local inline = pickfirstset(v.dialogInline,v.guiInline,v.inline, false)
			local hidden = CheckOptionHidden(v, options, path, appName)
			if not inline and not hidden then
				local entry = new()
				entry.value = k
				entry.text = v.name
				tinsert(tree,entry)
				if (v.childGroups or "tree") == "tree" then
					BuildSubTree(v,entry, options, path, appName)
				end
			end
		end
	end
	del(feedkeys)
	del(feedtmp)
	return tree
end

local function InjectInfo(control, options, option, path, rootframe, appName)
	local user = control.userdata
	for i,key in ipairs(path) do
		user[i] = key
	end
	user.rootframe = rootframe
	user.option = option
	user.options = options
	user.path = copy(path)
	user.appName = appName
	control:SetCallback("OnRelease", CleanUserData)
end


--[[
	options - root of the options table being fed
	container - widget that controls will be placed in
	rootframe - Frame object the options are in
	path - table with the keys to get to the group being fed
--]]

local function FeedOptions(appName, options,container,rootframe,path,group,inline)
	local feedkeys = new()
	local feedtmp = new()
	
	BuildSortedOptionsTable(group, feedkeys, feedtmp)
	
	for i, v in ipairs(feedtmp) do
		local k = feedkeys[v]
		local hidden = CheckOptionHidden(v, options, path, appName)
		if not hidden then
			if v.type == "group" then
				if inline or pickfirstset(v.dialogInline,v.guiInline,v.inline, false) then
					--Inline group
					local GroupContainer = gui:Create("InlineGroup")
					GroupContainer:SetTitle(v.name or "")
					GroupContainer.width = "fill"
					GroupContainer:SetLayout("flow")
					container:AddChild(GroupContainer)
					tinsert(path, k)
					FeedOptions(appName,options,GroupContainer,rootframe,path,v,true)
					tremove(path)
				end
			else
				tinsert(path, k)
				--Control to feed
				local control
				if v.type == "execute" then
					control = gui:Create("Button")
					control:SetText(v.name)
					control:SetCallback("OnClick",ActivateControl)
					
				elseif v.type == "input" then
					control = gui:Create("EditBox")
					control:SetLabel(v.name)
					control:SetCallback("OnEnterPressed",ActivateControl)
					control:SetText(CallOptionsFunction("get",v, options, path, appName))
					
				elseif v.type == "toggle" then
					control = gui:Create("CheckBox")
					control:SetLabel(v.name)
					control:SetValue(CallOptionsFunction("get",v, options, path, appName))
					control:SetCallback("OnValueChanged",ActivateControl)
					
				elseif v.type == "range" then
					control = gui:Create("Slider")
					control:SetLabel(v.name)
					control:SetSliderValues(v.min or 0,v.max or 100,v.bigStep or 0)
					control:SetValue(CallOptionsFunction("get",v, options, path, appName))
					control:SetCallback("OnValueChanged",ActivateControl)
					
				elseif v.type == "select" then
					control = gui:Create("Dropdown")
					control:SetLabel(v.name)
					control:SetList(v.values)
					control:SetValue(CallOptionsFunction("get",v, options, path, appName))
					control:SetCallback("OnValueChanged",ActivateControl)
					
				elseif v.type == "multiselect" then
					control = gui:Create("InlineGroup")
					control:SetLayout("Flow")
					control:SetTitle(v.name)
					control.width = "fill"
					
					local valuesort = new()
					local values = v.values
					local disabled = CheckOptionDisabled(v, options, path, appName)

					if values then
						for value, text in pairs(v.values) do
							tinsert(valuesort, value)
						end
						
						table.sort(valuesort)
						
						for i, value in ipairs(valuesort) do
							local text = values[value]
							local check = gui:Create("CheckBox")
							check:SetLabel(text)
							check.userdata.value = value
							check:SetDisabled(disabled)
							check:SetValue(CallOptionsFunction("get",v, options, path, appName, value))
							check:SetCallback("OnValueChanged",ActivateMultiControl)
							InjectInfo(check, options, v, path, rootframe, appName)
							check:SetCallback("OnEnter",OptionOnMouseOver)
							control:AddChild(check)
						end
					end
					del(valuesort)
					
				elseif v.type == "color" then
					--control = gui:Create("")
					
				elseif v.type == "keybinding" then
					--control = gui:Create("")
					
				elseif v.type == "header" then
					control = gui:Create("Heading")
					control:SetText(v.name)
					control.width = "fill"
					
				end
	
				--Common Init
				if control then
					if control.SetDisabled then
						local disabled = CheckOptionDisabled(v, options, path, appName)
						control:SetDisabled(disabled)
					end

					InjectInfo(control, options, v, path, rootframe, appName)
					control:SetCallback("OnEnter",OptionOnMouseOver)
					container:AddChild(control)
				end	
				tremove(path)			
			end
		end
	end
	
	del(feedkeys)
	del(feedtmp)
end

local function BuildPath(path, ...)
	for i = 1, select('#',...)  do
		tinsert(path, (select(i,...)))
	end
end
-- ... is the path up the tree to the current node, in reverse order (node, parent, grandparent)
local function GroupSelected(widget, event, uniquevalue)

	local user = widget.userdata
	
	local options = user.options
	local option = user.option
	local path = user.path
	local rootframe = user.rootframe
	
	local feedpath = new()
	for i, v in ipairs(path) do
		feedpath[i] = v
	end
	
	BuildPath(feedpath, string.split("\001", uniquevalue))
	
	local group = options
	for i, v in ipairs(feedpath) do
		group = GetSubOption(group, v)
	end	
	
	widget:ReleaseChildren()
	lib:FeedGroup(user.appName,options,widget,rootframe,feedpath,group)
	
	del(feedpath)
end




--[[
This function will feed one group, and any inline child groups into the given container
Select Groups will only have the selection control (tree, tabs, dropdown) fed in
and have a group selected, this event will trigger the feeding of child groups

Rules:
	If the group is Inline, FeedOptions
	If the group has no child groups, FeedOptions
	
	If the group is a tab or select group, FeedOptions then add the Group Control
	If the group is a tree group FeedOptions then
		its parent isn't a tree group:  then add the tree control containing this and all child tree groups
		if its parent is a tree group, its already a node on a tree
--]]

function lib:FeedGroup(appName,options,container,rootframe,path)
	local group = options
	--follow the path to get to the curent group
	local inline
	local grouptype, parenttype = nil, "none"
	
	for i, v in ipairs(path) do
		group = GetSubOption(group, v)
		inline = inline or pickfirstset(v.dialogInline,v.guiInline,v.inline, false)
		parenttype = grouptype
		grouptype = group.childGroups
	end
	
	if not parenttype then
		parenttype = "tree"
	end
	

	--check if the group has child groups
	local hasChildGroups
	for k, v in pairs(group.args) do
		if v.type == "group" and not pickfirstset(v.dialogInline,v.guiInline,v.inline, false) then
			hasChildGroups = true
		end
	end
	if group.plugins then
		for plugin, t in pairs(group.plugins) do
			for k, v in pairs(t) do
				if v.type == "group" and not pickfirstset(v.dialogInline,v.guiInline,v.inline, false) then
					hasChildGroups = true
				end
			end
		end
	end
	
	container:SetLayout("flow")

	if (not hasChildGroups) or inline then
		if container.type ~= "InlineGroup" then
			local scroll = gui:Create("ScrollFrame")
			
			scroll:SetLayout("flow")
			scroll.width = "fill"
			scroll.height = "fill"
			container:AddChild(scroll)
			container = scroll
		end
	end
	
	FeedOptions(appName,options,container,rootframe,path,group)

	if container.Type == "ScrollFrame" then
		local status = self:GetStatusTable(appName, path)
		if not status.scroll then
			status.scroll = {}
		end
		scroll:SetStatusTable(status.scroll)
	end
	
	if hasChildGroups and not inline then
		
		if grouptype == "tab" then

			local tab = gui:Create("TabGroup")
			InjectInfo(tab, options, group, path, rootframe, appName)
			tab:SetCallback("OnGroupSelected", GroupSelected)
			local status = lib:GetStatusTable(appName, path)
			if not status.groups then
				status.groups = {}
			end
			tab:SetStatusTable(status.groups)
			tab.width = "fill"
			tab.height = "fill"

			local tabs, text = BuildTabs(group, options, path, appName)
			tab:SetTabs(tabs, text)

			container:AddChild(tab)
			
		elseif grouptype == "select" then

			local select = gui:Create("DropdownGroup")
			InjectInfo(select, options, group, path, rootframe, appName)
			select:SetCallback("OnGroupSelected", GroupSelected)
			local status = lib:GetStatusTable(appName, path)
			if not status.groups then
				status.groups = {}
			end
			select:SetStatusTable(status.groups)
			select.width = "fill"
			select.height = "fill"
			
			container:AddChild(select)
			
		--assume tree group by default
		elseif parenttype ~= "tree" then

			local tree = gui:Create("TreeGroup")
			InjectInfo(tree, options, group, path, rootframe, appName)
			
			tree.width = "fill"
			tree.height = "fill"
			
			tree:SetCallback("OnGroupSelected", GroupSelected)
			
			local status = lib:GetStatusTable(appName, path)
			if not status.groups then
				status.groups = {}
			end
			local treedefinition = BuildTree(group, options, path, appName)
			tree:SetStatusTable(status.groups)
			
			tree:SetTree(treedefinition)

			if treedefinition[1] then
				tree:SelectByValue(status.groups.selected or treedefinition[1].value)
			end


			container:AddChild(tree)
		end
	end

end 

function lib:Open(appName)
	
	local app = reg:GetOptionsTable(appName)
	if not app then
		error(("%s isn't registed with AceConfigRegistry, unable to open config"):format(appName), 2)
	end	
	local options = app("dialog", MAJOR)
	
	local f
	if not self.OpenFrames[appName] then
		f = gui:Create("Frame")
		self.OpenFrames[appName] = f
	else
		f = self.OpenFrames[appName]
	end
	f:ReleaseChildren()
	f:SetCallback("OnClose", FrameOnClose)
	f.userdata.appName = appName
	f:SetTitle(options.name or "")
	local status = lib:GetStatusTable(appName)
	f:SetStatusTable(status)

	local path = new()
	
	self:FeedGroup(appName,options,f,f,path)
	f:Show()
	del(path)
end
