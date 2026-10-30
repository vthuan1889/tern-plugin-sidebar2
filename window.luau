-- sidebar2/window.luau
-- Fixed Kanban Sidebar (TODO / Processing / DONE) with 3-Level Hierarchy:
--   Level 1: Host + Session name (movable between TODO, Processing, DONE)
--   Level 2: Tabs in each session
--   Level 3: Panes in each tab

local ui = tern.ui

local SIDEBAR_TITLE = "Kanban"
local SIDEBAR_ABOUT = "Fixed Kanban sidebar (TODO / Processing / DONE) organizing Host + Session, Tabs, and Panes."

type GroupId = "todo" | "doing" | "done"

type GroupSpec = {
	id: GroupId,
	label: string,
	short: string,
	tone: string,
	next_id: GroupId,
}

local GROUPS: { GroupSpec } = {
	{ id = "todo", label = "TODO", short = "TODO", tone = "info", next_id = "doing" },
	{ id = "doing", label = "PROCESSING", short = "DOING", tone = "warning", next_id = "done" },
	{ id = "done", label = "DONE", short = "DONE", tone = "success", next_id = "todo" },
}

local GROUP_BY_ID: { [ string ]: GroupSpec } = {}
for _, g in ipairs(GROUPS) do
	GROUP_BY_ID[g.id] = g
end

type PersistedState = {
	visible: boolean,
	side: "left" | "right",
	ratio: number,
	cols_est: number,
	groups: { [string]: GroupId },
	manual_groups: { [string]: boolean },
	fold_groups: { [string]: boolean },
	fold_sessions: { [string]: boolean },
	fold_tabs: { [string]: boolean },
	owned_panes: { [string]: boolean },
}

local function clamp(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

local function load_state(): PersistedState
	local ok, raw = pcall(tern.kv.get, "state")
	local tbl = if ok and type(raw) == "table" then raw else {}
	local visible = true
	if type(tbl.visible) == "boolean" then
		visible = tbl.visible
	elseif type(tbl.auto_open) == "boolean" then
		visible = tbl.auto_open
	end
	local side: "left" | "right" = if tbl.side == "right" then "right" else "left"
	local ratio = 0.20
	local cols_est = if type(tbl.cols_est) == "number" then clamp(tbl.cols_est, 60, 600) else 180
	return {
		visible = visible,
		side = side,
		ratio = ratio,
		cols_est = cols_est,
		groups = if type(tbl.groups) == "table" then tbl.groups else {},
		manual_groups = if type(tbl.manual_groups) == "table" then tbl.manual_groups else {},
		fold_groups = if type(tbl.fold_groups) == "table" then tbl.fold_groups else {},
		fold_sessions = if type(tbl.fold_sessions) == "table" then tbl.fold_sessions else {},
		fold_tabs = if type(tbl.fold_tabs) == "table" then tbl.fold_tabs else {},
		owned_panes = if type(tbl.owned_panes) == "table" then tbl.owned_panes else {},
	}
end

local persisted: PersistedState = load_state()

local function save_state()
	pcall(tern.kv.set, "state", persisted)
end

-- Runtime state (per window VM)
local busy_lock = false
local picked_skey: string? = nil
local picked_tab_id: number? = nil
local picked_tab_sess: number? = nil
local painted_fp: { [number]: string } = {}
local opened_at_ms: { [number]: number } = {}
local synced_tab_ratio: { [number]: number } = {}
local last_user_pane_by_tab: { [number]: number } = {}
local last_active_session_id: number? = nil
local last_active_tab_id: number? = nil
local current_stage_label = "TODO"
local current_stage_tone = "info"

-- ---------------------------------------------------------------------------
-- Helper: Identify owned sidebar2 canvas panes
-- ---------------------------------------------------------------------------
local function live_host_canvases(cx: WindowCx): { [number]: boolean }
	local map: { [number]: boolean } = {}
	local ok_c, clist = pcall(function()
		return cx.canvas:list()
	end)
	if ok_c and type(clist) == "table" then
		for _, c in ipairs(clist) do
			if c.owner == tern.plugin.id then
				map[c.pane] = true
			end
		end
	end
	return map
end

local function owned_canvases(cx: WindowCx): { [number]: boolean }
	local map = live_host_canvases(cx)
	local ok_p, plist = pcall(function()
		return cx.session:panes()
	end)
	if ok_p and type(plist) == "table" then
		for _, p in ipairs(plist) do
			local pkey = tostring(p.pane)
			local is_canvas = (p.kind == "canvas" or p.program == "tern.canvas" or p.block == "tern.canvas" or p.block == "plugin.tern.canvas")
			if persisted.owned_panes[pkey] or (is_canvas and (p.title == SIDEBAR_TITLE or p.title == "Canvas")) then
				map[p.pane] = true
			end
		end
	end
	return map
end

local function host_pane_map(cx: WindowCx, host_id: number): { [number]: boolean }
	local set: { [number]: boolean } = {}
	local ok_h, hlist = pcall(function()
		return cx.hosts:list()
	end)
	if ok_h and type(hlist) == "table" then
		for _, h in ipairs(hlist) do
			if h.id == host_id and type(h.panes) == "table" then
				for _, pid in ipairs(h.panes) do
					set[pid] = true
				end
			end
		end
	end
	return set
end

local function close_stale_canvases(cx: WindowCx, active_host_id: number?)
	local live = live_host_canvases(cx)
	local on_host = if active_host_id ~= nil then host_pane_map(cx, active_host_id) else nil
	local now = tern.now()
	local dirty = false
	local ok_p, plist = pcall(function()
		return cx.session:panes()
	end)
	if ok_p and type(plist) == "table" then
		for _, p in ipairs(plist) do
			if (not on_host or on_host[p.pane]) and not live[p.pane] then
				local opened_t = opened_at_ms[p.pane]
				if not opened_t or (now - opened_t) > 2500 then
					local pkey = tostring(p.pane)
					local is_canvas = (p.kind == "canvas" or p.program == "tern.canvas" or p.block == "tern.canvas" or p.block == "plugin.tern.canvas")
					if persisted.owned_panes[pkey] or (is_canvas and (p.title == SIDEBAR_TITLE or p.title == "Canvas" or p.title == "TestRemoteCanvas")) then
						persisted.owned_panes[pkey] = nil
						painted_fp[p.pane] = nil
						opened_at_ms[p.pane] = nil
						dirty = true
						pcall(function()
							cx.layout:close(p.pane)
						end)
					end
				end
			end
		end
	end
	if dirty then
		save_state()
	end
end

local function needs_hydration(cx: WindowCx, spane: number): boolean
	local opened_t = opened_at_ms[spane]
	if opened_t and (tern.now() - opened_t) < 2500 then
		return true
	end
	local ok_p, pinfo = pcall(function()
		return cx.session:pane(spane)
	end)
	if ok_p and pinfo and pinfo.title ~= SIDEBAR_TITLE then
		return true
	end
	return false
end

local function collect_tree_panes(node: TabTree?, out: { number })
	if not node then
		return
	end
	if type(node.pane) == "number" then
		table.insert(out, node.pane)
		return
	end
	collect_tree_panes(node[1], out)
	collect_tree_panes(node[2], out)
end

local function tab_all_panes(cx: WindowCx, tab_id: number): { number }
	local out: { number } = {}
	local ok, lay = pcall(function()
		return cx.session:layout(tab_id)
	end)
	if ok and lay then
		collect_tree_panes(lay.root, out)
		if type(lay.floats) == "table" then
			for _, f in ipairs(lay.floats) do
				if type(f.pane) == "number" then
					table.insert(out, f.pane)
				end
			end
		end
	end
	return out
end

local function first_user_pane(cx: WindowCx, tab_id: number, owned: { [number]: boolean }): number?
	local remembered = last_user_pane_by_tab[tab_id]
	local panes = tab_all_panes(cx, tab_id)
	if remembered and not owned[remembered] then
		for _, p in ipairs(panes) do
			if p == remembered then
				return remembered
			end
		end
	end
	for _, p in ipairs(panes) do
		if not owned[p] then
			return p
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Helper: Ensure status bar is visible so the Show/Hide button is always accessible
-- ---------------------------------------------------------------------------
local function ensure_status_bar(cx: WindowCx)
	pcall(function()
		if cx.settings:get("status_bar") ~= true then
			cx.settings:set("status_bar", true)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- 3-Level Data Model & Collector
-- ---------------------------------------------------------------------------
type PaneEntry = {
	id: number,
	kind: string,
	title: string,
	sub: string?,
	busy: boolean,
	err: boolean,
	focused: boolean,
}

type TabEntry = {
	id: number,
	session_id: number,
	pos: number,
	title: string,
	busy: boolean,
	current: boolean,
	panes: { PaneEntry },
}

type SessionEntry = {
	id: number,
	name: string,
	host_id: number,
	host_name: string,
	host_kind: string,
	host_state: string,
	skey: string,
	group: GroupId,
	current: boolean,
	busy: boolean,
	tabs: { TabEntry },
	pane_count: number,
}

type CollectedData = {
	sessions: { SessionEntry },
	by_group: { [GroupId]: { SessionEntry } },
	by_skey: { [string]: SessionEntry },
	active_session_id: number?,
	active_tab_id: number?,
	focused_pane: number?,
	owned: { [number]: boolean },
}

local function short_text(s: string?, max_len: number): string
	if not s or s == "" then
		return ""
	end
	local clean = string.gsub(s, "[\r\n\t]+", " ")
	if #clean <= max_len then
		return clean
	end
	return string.sub(clean, 1, max_len - 1) .. "…"
end

local function pane_glyph(kind: string): string
	if kind == "agent" or kind == "carly" then
		return "✦"
	elseif kind == "file" then
		return "📄"
	elseif kind == "git" then
		return "⎇"
	elseif kind == "browser" then
		return "🌐"
	elseif kind == "database" then
		return "🛢"
	elseif kind == "notebook" then
		return "📓"
	elseif kind == "board" then
		return "📋"
	elseif kind == "procs" or kind == "profile" then
		return "⚙"
	end
	return ">_"
end

local function collect_data(cx: WindowCx): CollectedData
	local owned = owned_canvases(cx)
	local focused = cx.session:focused()

	-- 1. Hosts
	local host_by_id: { [number]: ManagedHost } = {}
	local current_host_id = 0
	local ok_h, hlist = pcall(function()
		return cx.hosts:list()
	end)
	if ok_h and type(hlist) == "table" then
		for _, h in ipairs(hlist) do
			host_by_id[h.id] = h
			if h.current then
				current_host_id = h.id
			end
		end
	end

	-- 2. Agent states
	local agent_state_by_pane: { [number]: string } = {}
	local ok_a, alist = pcall(function()
		return cx.agents:list()
	end)
	if ok_a and type(alist) == "table" then
		for _, a in ipairs(alist) do
			if type(a.pane) == "number" and type(a.state) == "string" then
				agent_state_by_pane[a.pane] = a.state
			end
		end
	end

	-- 3. Panes by id and by tab
	local pane_info_by_id: { [number]: PaneInfo } = {}
	local panes_by_tab_fallback: { [number]: { number } } = {}
	local ok_p, plist = pcall(function()
		return cx.session:panes()
	end)
	if ok_p and type(plist) == "table" then
		for _, p in ipairs(plist) do
			if not owned[p.pane] and not p.parked then
				pane_info_by_id[p.pane] = p
				if type(p.tab) == "number" then
					local arr = panes_by_tab_fallback[p.tab]
					if not arr then
						arr = {}
						panes_by_tab_fallback[p.tab] = arr
					end
					table.insert(arr, p.pane)
				end
			end
		end
	end

	-- 4. Current session & active tab
	local active_session_id: number? = nil
	local ok_cs, cur_sess = pcall(function()
		return cx.sessions:current()
	end)
	if ok_cs and cur_sess and type(cur_sess.id) == "number" then
		active_session_id = cur_sess.id
	end

	local active_tab_id: number? = nil
	if focused then
		active_tab_id = cx.session:tab_of(focused)
		if not owned[focused] and active_tab_id then
			last_user_pane_by_tab[active_tab_id] = focused
		end
	end

	-- 5. Tabs grouped by session
	local raw_tabs_by_sess: { [number]: { TabInfo } } = {}
	local ok_t, tlist = pcall(function()
		return cx.session:tabs()
	end)
	if ok_t and type(tlist) == "table" then
		for _, t in ipairs(tlist) do
			local arr = raw_tabs_by_sess[t.session]
			if not arr then
				arr = {}
				raw_tabs_by_sess[t.session] = arr
			end
			table.insert(arr, t)
		end
	end
	for _, arr in pairs(raw_tabs_by_sess) do
		table.sort(arr, function(a, b)
			if a.position ~= b.position then
				return a.position < b.position
			end
			return a.id < b.id
		end)
	end

	if active_session_id and raw_tabs_by_sess[active_session_id] then
		local belongs = false
		if active_tab_id then
			for _, t in ipairs(raw_tabs_by_sess[active_session_id]) do
				if t.id == active_tab_id then
					belongs = true
					break
				end
			end
		end
		if not belongs then
			local first_t = raw_tabs_by_sess[active_session_id][1]
			active_tab_id = if first_t then first_t.id else nil
		end
	end
	-- 6. Managed sessions across all hosts
	local raw_sessions: { ManagedSession } = {}
	local ok_s, slist = pcall(function()
		return cx.sessions:list()
	end)
	if ok_s and type(slist) == "table" and #slist > 0 then
		raw_sessions = slist
	else
		local ok_ls, ls = pcall(function()
			return cx.session:sessions()
		end)
		if ok_ls and type(ls) == "table" then
			for _, s in ipairs(ls) do
				table.insert(raw_sessions, {
					id = s.id,
					name = s.name,
					host = current_host_id,
					current = s.current,
					locked = s.locked,
					tabs = #s.tabs,
				})
			end
		end
	end

	table.sort(raw_sessions, function(a, b)
		local ha = host_by_id[a.host]
		local hb = host_by_id[b.host]
		local ka = if ha then ha.kind else "local"
		local kb = if hb then hb.kind else "local"
		if ka ~= kb then
			return ka == "local"
		end
		local na = if ha then ha.name else "local"
		local nb = if hb then hb.name else "local"
		if na ~= nb then
			return na < nb
		end
		return a.id < b.id
	end)

	local sessions: { SessionEntry } = {}
	local by_group: { [GroupId]: { SessionEntry } } = {
		todo = {},
		doing = {},
		done = {},
	}
	local by_skey: { [string]: SessionEntry } = {}
	local state_dirty = false

	for _, s in ipairs(raw_sessions) do
		local h = host_by_id[s.host]
		local host_name = if h and h.name ~= "" then h.name else "local"
		local host_kind = if h and h.kind then h.kind else "local"
		local host_state = if h and h.state then h.state else "connected"
		local skey = host_name .. "::" .. s.name
		local is_cur_sess = (s.current == true) or (active_session_id == s.id)
		if is_cur_sess and not active_session_id then
			active_session_id = s.id
		end

		local tab_entries: { TabEntry } = {}
		local sess_busy = false
		local sess_pane_count = 0
		local stabs = raw_tabs_by_sess[s.id] or {}

		for idx, t in ipairs(stabs) do
			local ordered_ids = tab_all_panes(cx, t.id)
			if #ordered_ids == 0 and panes_by_tab_fallback[t.id] then
				ordered_ids = panes_by_tab_fallback[t.id]
			end
			local seen_p: { [number]: boolean } = {}
			local pane_entries: { PaneEntry } = {}
			local tab_busy = false
			local primary_user_title: string? = nil

			for _, pid in ipairs(ordered_ids) do
				if not seen_p[pid] and not owned[pid] then
					seen_p[pid] = true
					local pinfo = pane_info_by_id[pid]
					if pinfo then
						local astate = agent_state_by_pane[pid]
						local pbusy = (pinfo.busy == true)
							or (pinfo.running ~= nil)
							or (astate == "working")
						local perr = (pinfo.error ~= nil)
							or (pinfo.last ~= nil and pinfo.last.status ~= 0)
							or (astate == "waiting_input")
						local pfocused = (focused == pid) or (last_user_pane_by_tab[t.id] == pid and t.id == active_tab_id)
						local raw_title = if pinfo.title and pinfo.title ~= "" and pinfo.title ~= SIDEBAR_TITLE
							then pinfo.title
							elseif pinfo.program and pinfo.program ~= "" then pinfo.program
							else (pinfo.kind or "shell")
						if not primary_user_title then
							primary_user_title = raw_title
						end
						local sub: string? = nil
						if pinfo.running and pinfo.running.line and pinfo.running.line ~= "" then
							sub = short_text(pinfo.running.line, 24)
						elseif astate and astate ~= "idle" then
							sub = astate
						end
						if pbusy then
							tab_busy = true
						end
						table.insert(pane_entries, {
							id = pid,
							kind = pinfo.kind or "terminal",
							title = short_text(raw_title, 26),
							sub = sub,
							busy = pbusy,
							err = perr,
							focused = pfocused,
						})
					end
				end
			end

			sess_pane_count += #pane_entries
			if tab_busy then
				sess_busy = true
			end

			local tab_title = if t.name and t.name ~= "" and t.name ~= SIDEBAR_TITLE
				then t.name
				elseif primary_user_title and primary_user_title ~= "" then primary_user_title
				elseif t.title and t.title ~= "" and t.title ~= SIDEBAR_TITLE then t.title
				elseif t.program and t.program ~= "" then t.program
				else ("Tab " .. tostring(idx))

			-- Skip pure-sidebar transient tabs if there are other tabs in the session
			local only_sidebar = (#pane_entries == 0 and #stabs > 1)
			if not only_sidebar then
				table.insert(tab_entries, {
					id = t.id,
					session_id = s.id,
					pos = #tab_entries + 1,
					title = short_text(tab_title, 24),
					busy = tab_busy,
					current = is_cur_sess and (t.id == active_tab_id),
					panes = pane_entries,
				})
			end
		end

		local grp: GroupId = persisted.groups[skey] or "todo"
		if grp ~= "todo" and grp ~= "doing" and grp ~= "done" then
			grp = "todo"
		end
		if sess_busy and grp == "todo" and not persisted.manual_groups[skey] then
			grp = "doing"
			persisted.groups[skey] = "doing"
			state_dirty = true
		end
		persisted.groups[skey] = grp

		if is_cur_sess then
			local gspec = GROUP_BY_ID[grp] or GROUPS[1]
			current_stage_label = gspec.short
			current_stage_tone = gspec.tone
		end

		local entry: SessionEntry = {
			id = s.id,
			name = s.name,
			host_id = s.host,
			host_name = host_name,
			host_kind = host_kind,
			host_state = host_state,
			skey = skey,
			group = grp,
			current = is_cur_sess,
			busy = sess_busy,
			tabs = tab_entries,
			pane_count = sess_pane_count,
		}
		table.insert(sessions, entry)
		table.insert(by_group[grp], entry)
		by_skey[skey] = entry
	end

	if state_dirty then
		save_state()
	end

	return {
		sessions = sessions,
		by_group = by_group,
		by_skey = by_skey,
		active_session_id = active_session_id,
		active_tab_id = active_tab_id,
		focused_pane = focused,
		owned = owned,
	}
end

-- ---------------------------------------------------------------------------
-- View Fingerprint & Node Builder
-- ---------------------------------------------------------------------------
local function build_fingerprint(data: CollectedData): string
	local parts: { string } = {
		tostring(persisted.visible),
		persisted.side,
		tostring(picked_skey or ""),
		tostring(picked_tab_id or ""),
		tostring(data.active_session_id or 0),
		tostring(data.active_tab_id or 0),
		tostring(data.focused_pane or 0),
	}
	for _, g in ipairs(GROUPS) do
		local gfold = persisted.fold_groups[g.id] == true
		table.insert(parts, g.id .. ":" .. tostring(gfold))
		for _, s in ipairs(data.by_group[g.id]) do
			local sfold = persisted.fold_sessions[s.skey] == true
			table.insert(
				parts,
				table.concat({
					s.skey,
					s.group,
					tostring(s.current),
					tostring(s.busy),
					tostring(sfold),
					tostring(#s.tabs),
					tostring(s.pane_count),
				}, ",")
			)
			if not gfold and not sfold then
				for _, t in ipairs(s.tabs) do
					local tkey = tostring(t.id)
					local tfold = persisted.fold_tabs[tkey] == true
					table.insert(
						parts,
						table.concat({
							tkey,
							tostring(t.pos),
							t.title,
							tostring(t.current),
							tostring(t.busy),
							tostring(tfold),
							tostring(#t.panes),
						}, ";")
					)
					if not tfold then
						for _, p in ipairs(t.panes) do
							table.insert(
								parts,
								table.concat({
									tostring(p.id),
									p.kind,
									p.title,
									tostring(p.sub or ""),
									tostring(p.busy),
									tostring(p.err),
									tostring(p.focused),
								}, "/")
							)
						end
					end
				end
			end
		end
	end
	return table.concat(parts, "|")
end

local function build_view(data: CollectedData): (Node, Node)
	local root_children: { Node } = {}

	-- 1. Top Toolbar
	local side_arrow = if persisted.side == "left" then "⇄ R" else "L ⇄"
	local toolbar = ui.node("row", {
		key = "toolbar",
		role = "sidebar2.toolbar",
		justify = "between",
		align = "center",
	}, {
		ui.row({
			ui.text({
				ui.span("KANBAN", "strong"),
				ui.span(" · " .. tostring(#data.sessions), "muted"),
			}),
		}),
		ui.row({
			ui.node("badge", {
				key = "btn_side",
				text = side_arrow,
				tone = "neutral",
				actions = { click = "flip_side" },
			}),
			ui.node("badge", {
				key = "btn_fold_all",
				text = "⊟",
				tone = "neutral",
				actions = { click = "fold_all" },
			}),
			ui.node("badge", {
				key = "btn_refresh",
				text = "↻",
				tone = "neutral",
				actions = { click = "refresh" },
			}),
			ui.node("badge", {
				key = "btn_hide",
				text = "Hide ✕",
				tone = "error",
				actions = { click = "hide_sidebar" },
			}),
		}),
	})
	table.insert(root_children, toolbar)

	-- 2. Pick Mode Banner (when a Level 1 session or Level 2 tab is picked for drag-and-drop)
	if picked_skey then
		local picked_entry = data.by_skey[picked_skey]
		local picked_label = if picked_entry
			then (picked_entry.host_name .. " / " .. picked_entry.name)
			else picked_skey
		table.insert(
			root_children,
			ui.node("row", {
				key = "pick_banner",
				role = "sidebar2.pick_banner",
				justify = "between",
				align = "center",
			}, {
				ui.text({
					ui.span("⇄ Move: ", "strong info"),
					ui.span(short_text(picked_label, 20), "strong"),
				}),
				ui.node("badge", {
					key = "cancel_pick",
					text = "Cancel ✕",
					tone = "neutral",
					actions = { click = "cancel_pick" },
				}),
			})
		)
	elseif picked_tab_id then
		local picked_tab_label = "Tab"
		for _, s in ipairs(data.sessions) do
			if s.id == picked_tab_sess then
				for _, t in ipairs(s.tabs) do
					if t.id == picked_tab_id then
						picked_tab_label = "#" .. tostring(t.pos) .. " " .. t.title
						break
					end
				end
			end
		end
		table.insert(
			root_children,
			ui.node("row", {
				key = "pick_tab_banner",
				role = "sidebar2.pick_banner",
				justify = "between",
				align = "center",
			}, {
				ui.text({
					ui.span("↕ Move Tab: ", "strong warning"),
					ui.span(short_text(picked_tab_label, 18), "strong"),
				}),
				ui.node("badge", {
					key = "cancel_pick_tab",
					text = "Cancel ✕",
					tone = "neutral",
					actions = { click = "cancel_pick" },
				}),
			})
		)
	end

	-- 3. Kanban Groups: TODO, Processing, DONE
	for _, g in ipairs(GROUPS) do
		local g_entries = data.by_group[g.id] or {}
		local g_folded = persisted.fold_groups[g.id] == true
		local g_chev = if g_folded then "▸" else "▾"
		local group_children: { Node } = {}

		local head_click = if picked_skey then ("drop_group=" .. g.id) else ("fold_group=" .. g.id)
		local head_right_badge = if picked_skey
			then ui.badge("↓ Drop here", g.tone)
			else ui.badge(tostring(#g_entries), g.tone)
		local group_head = ui.node("row", {
			key = "ghead_" .. g.id,
			role = "sidebar2.group_head",
			justify = "between",
			align = "center",
			actions = {
				click = head_click,
				menu = {
					"fold_group=" .. g.id,
					"new_session_in=" .. g.id,
				},
			},
		}, {
			ui.text({
				ui.span(g.label, "strong " .. g.tone),
			}),
			ui.row({
				head_right_badge,
				ui.text({ ui.span(g_chev, "muted") }),
			}),
		})
		table.insert(group_children, group_head)

		if picked_skey then
			table.insert(
				group_children,
				ui.node("row", {
					key = "drop_zone_" .. g.id,
					role = "sidebar2.drop_zone",
					justify = "center",
					align = "center",
					actions = { click = "drop_group=" .. g.id },
				}, {
					ui.text({
						ui.span("↓ Move session to " .. g.label, "strong " .. g.tone),
					}),
				})
			)
		end

		if not g_folded then
			if #g_entries == 0 then
				table.insert(
					group_children,
					ui.node("row", {
						key = "empty_" .. g.id,
						role = "sidebar2.empty",
					}, {
						ui.text({ ui.span("No sessions in " .. g.label, "muted") }),
					})
				)
			else
				for _, sess in ipairs(g_entries) do
					local s_folded = persisted.fold_sessions[sess.skey] == true
					local s_chev = if s_folded then "▸" else "▾"
					local is_picked = (picked_skey == sess.skey)
					local grip_icon = if is_picked then "🎯" else "⠿"
					local l1_role = if sess.current then "sidebar2.level1.current" else "sidebar2.level1"
					local host_badge_tone = if sess.host_kind == "remote" then "info" else "neutral"
					local sess_status = if sess.busy then " ⟳" elseif sess.current then " ●" else ""

					local l1_menu = {
						"pick=" .. sess.skey,
						"move_todo=" .. sess.skey,
						"move_doing=" .. sess.skey,
						"move_done=" .. sess.skey,
						"new_tab_in=" .. tostring(sess.id),
						"rename_sess=" .. tostring(sess.id),
					}

					-- Level 1 Row: Host + Session name (submenu icon at end, no stage label)
					local l1_row = ui.node("row", {
						key = "l1_" .. sess.skey,
						role = l1_role,
						mark = if is_picked then "pick" else nil,
						justify = "between",
						align = "center",
					}, {
						ui.node("badge", {
							key = "pick_s_" .. sess.skey,
							text = grip_icon,
							tone = if is_picked then "warning" else "neutral",
							actions = { click = "pick=" .. sess.skey, menu = l1_menu },
						}),
						ui.node("row", {
							key = "title_s_" .. sess.skey,
							role = "sidebar2.l1_title",
							align = "center",
							actions = {
								click = "focus_sess=" .. tostring(sess.id),
								menu = l1_menu,
							},
						}, {
							ui.badge(sess.host_name, host_badge_tone),
							ui.text({
								ui.span(
									short_text(sess.name, 20) .. sess_status,
									if sess.current then "strong" else nil
								),
								ui.span(" " .. tostring(#sess.tabs) .. "t", "muted"),
							}),
						}),
						ui.node("badge", {
							key = "fold_s_" .. sess.skey,
							text = s_chev,
							tone = "neutral",
							actions = { click = "fold_sess=" .. sess.skey, menu = l1_menu },
						}),
					})
					table.insert(group_children, l1_row)

					-- Level 2: Tabs inside Session (non-nested interactive children)
					if not s_folded then
						local can_reorder_tabs = #sess.tabs >= 2
						for _, tab in ipairs(sess.tabs) do
							local tkey = tostring(tab.id)
							local has_sub = #tab.panes >= 2
							local t_folded = persisted.fold_tabs[tkey] == true
							local t_chev = if t_folded then "▸" else "▾"
							local is_tab_picked = (picked_tab_id == tab.id)
							local is_tab_drop_target = (picked_tab_id ~= nil and picked_tab_sess == sess.id and picked_tab_id ~= tab.id)
							local l2_role = if tab.current then "sidebar2.level2.current" else "sidebar2.level2"
							local tab_marker = if tab.busy then " ⟳" elseif tab.current then " ●" else ""
							local focus_tab_act = "focus_tab=" .. tostring(sess.id) .. ":" .. tkey
							local pick_tab_act = "pick_tab=" .. tostring(sess.id) .. ":" .. tkey
							local drop_tab_act = "drop_tab=" .. tostring(tab.pos)
							local primary_tab_act = if is_tab_drop_target then drop_tab_act else focus_tab_act

							local l2_menu: { string } = { focus_tab_act }
							if can_reorder_tabs then
								table.insert(l2_menu, pick_tab_act)
								if tab.pos > 1 then
									table.insert(l2_menu, "tab_move=" .. tkey .. ":" .. tostring(tab.pos - 1))
								end
								if tab.pos < #sess.tabs then
									table.insert(l2_menu, "tab_move=" .. tkey .. ":" .. tostring(tab.pos + 1))
								end
							end
							table.insert(l2_menu, "rename_tab=" .. tkey)
							table.insert(l2_menu, "close_tab=" .. tkey)

							local l2_children: { Node } = {}
							if can_reorder_tabs then
								table.insert(
									l2_children,
									ui.node("badge", {
										key = "pick_t_" .. tkey,
										text = if is_tab_picked then "🎯" elseif is_tab_drop_target then "↕" else "⠿",
										tone = if is_tab_picked
											then "warning"
											elseif is_tab_drop_target then "info"
											else "neutral",
										actions = {
											click = if is_tab_drop_target then drop_tab_act else pick_tab_act,
											menu = l2_menu,
										},
									})
								)
							end
							table.insert(
								l2_children,
								ui.node("row", {
									key = "title_t_" .. tkey,
									role = "sidebar2.l2_title",
									align = "center",
									actions = { click = primary_tab_act, menu = l2_menu },
								}, {
									ui.text({
										ui.span("#" .. tostring(tab.pos) .. " ", "muted"),
										ui.span(
											tab.title .. tab_marker,
											if tab.current then "strong" else nil
										),
										if has_sub
											then ui.span(" " .. tostring(#tab.panes) .. "p", "muted")
											else ui.span("", nil),
									}),
								})
							)

							if is_tab_drop_target then
								table.insert(
									l2_children,
									ui.node("badge", {
										key = "drop_t_" .. tkey,
										text = "↕ #" .. tostring(tab.pos),
										tone = "info",
										actions = { click = drop_tab_act },
									})
								)
							elseif has_sub then
								table.insert(
									l2_children,
									ui.node("badge", {
										key = "fold_t_" .. tkey,
										text = t_chev,
										tone = "neutral",
										actions = { click = "fold_tab=" .. tkey, menu = l2_menu },
									})
								)
							end
							local l2_row = ui.node("row", {
								key = "l2_" .. tkey,
								role = l2_role,
								mark = if is_tab_picked then "pick" else nil,
								justify = "between",
								align = "center",
							}, l2_children)
							table.insert(group_children, l2_row)

							-- Level 3: Panes inside Tab (only when tab has 2+ panes)
							if has_sub and not t_folded then
								for _, pane in ipairs(tab.panes) do
									local pkey = tostring(pane.id)
									local l3_role = if pane.focused
										then "sidebar2.level3.current"
										else "sidebar2.level3"
									local focus_pane_act = "focus_pane="
										.. tostring(sess.id)
										.. ":"
										.. tkey
										.. ":"
										.. pkey
									local status_badge: Node
									if pane.err then
										status_badge = ui.badge("!", "error")
									elseif pane.busy then
										status_badge = ui.badge("⟳", "warning")
									elseif pane.focused then
										status_badge = ui.badge("●", "info")
									else
										status_badge = ui.text({ ui.span(pane.kind, "muted") })
									end

									local label_spans: { Span | string } = {
										ui.span(pane_glyph(pane.kind) .. " ", "muted"),
										ui.span(pane.title, if pane.focused then "strong" else nil),
									}
									if pane.sub and pane.sub ~= "" then
										table.insert(label_spans, ui.span(" · " .. pane.sub, "muted"))
									end

									local l3_row = ui.node("row", {
										key = "l3_" .. pkey,
										role = l3_role,
										justify = "between",
										align = "center",
										actions = {
											click = focus_pane_act,
											menu = {
												focus_pane_act,
												"split_right=" .. pkey,
												"split_down=" .. pkey,
												"close_pane=" .. pkey,
											},
										},
									}, {
										ui.text(label_spans),
										status_badge,
									})
									table.insert(group_children, l3_row)
								end
							end
						end
					end
				end
			end
		end

		table.insert(
			root_children,
			ui.node("col", {
				key = "group_" .. g.id,
				role = "sidebar2.group",
			}, group_children)
		)
	end

	local view = ui.node("col", {
		key = "sidebar2_root",
		role = "sidebar2.root",
	}, root_children)

	local dock = ui.node("row", {
		key = "sidebar2_dock",
		role = "sidebar2.dock",
		justify = "between",
		align = "center",
	}, {
		ui.row({
			ui.node("badge", {
				key = "dock_new_sess",
				text = "+ Session",
				tone = "info",
				actions = { click = "new_session" },
			}),
			ui.node("badge", {
				key = "dock_new_tab",
				text = "+ Tab",
				tone = "neutral",
				actions = { click = "new_tab" },
			}),
			ui.node("badge", {
				key = "dock_move",
				text = "Move…",
				tone = "warning",
				actions = { click = "move_modal" },
			}),
		}),
		ui.node("badge", {
			key = "dock_hide",
			text = "Hide ✕",
			tone = "neutral",
			actions = { click = "hide_sidebar" },
		}),
	})

	return view, dock
end

-- ---------------------------------------------------------------------------
-- Fixed Sidebar Layout Engine (Per-Host Canvas + Ratio Sync + Refocus)
-- ---------------------------------------------------------------------------
local function close_all_sidebars(cx: WindowCx)
	local owned = owned_canvases(cx)
	for spane, _ in pairs(owned) do
		painted_fp[spane] = nil
		persisted.owned_panes[tostring(spane)] = nil
		pcall(function()
			cx.layout:close(spane)
		end)
	end
	close_stale_canvases(cx)
	save_state()
	table.clear(synced_tab_ratio)
end

local function cleanup_orphan_sidebar_tabs(cx: WindowCx, owned: { [number]: boolean }, active_session_id: number?)
	if not active_session_id then
		return
	end
	local ok_t, tlist = pcall(function()
		return cx.session:tabs()
	end)
	if not ok_t or type(tlist) ~= "table" then
		return
	end
	local sess_tabs: { TabInfo } = {}
	for _, t in ipairs(tlist) do
		if t.session == active_session_id then
			table.insert(sess_tabs, t)
		end
	end
	if #sess_tabs <= 1 then
		return
	end

	-- Find a tab in this session that has at least one user pane
	local fallback_user_tab: number? = nil
	local orphan_spane_tabs: { { tab_id: number, spane: number } } = {}
	for _, t in ipairs(sess_tabs) do
		local all_p = tab_all_panes(cx, t.id)
		local has_user = false
		local spane_in_tab: number? = nil
		for _, pid in ipairs(all_p) do
			if owned[pid] then
				spane_in_tab = pid
			else
				has_user = true
			end
		end
		if has_user and not fallback_user_tab then
			fallback_user_tab = t.id
		elseif not has_user and spane_in_tab and #all_p == 1 then
			table.insert(orphan_spane_tabs, { tab_id = t.id, spane = spane_in_tab })
		end
	end

	if fallback_user_tab and #orphan_spane_tabs > 0 then
		for _, item in ipairs(orphan_spane_tabs) do
			local u = first_user_pane(cx, fallback_user_tab, owned)
			if u then
				pcall(function()
					cx.layout:move_to_tab(item.spane, fallback_user_tab, { focus = false })
				end)
				pcall(function()
					cx.layout:focus(u)
				end)
			else
				pcall(function()
					cx.layout:close(item.spane)
				end)
			end
		end
	end
end

local function find_host_sidebar(
	cx: WindowCx,
	host_id: number,
	active_tab_id: number?,
	_owned: { [number]: boolean }
): number?
	local live = live_host_canvases(cx)
	local host_pane_set = host_pane_map(cx, host_id)

	local chosen: number? = nil
	local extras: { number } = {}
	for spane, _ in pairs(live) do
		local tab_id = cx.session:tab_of(spane)
		local on_host = host_pane_set[spane] or (active_tab_id ~= nil and tab_id == active_tab_id)
		if on_host then
			if active_tab_id and tab_id == active_tab_id and chosen ~= spane then
				if chosen then
					table.insert(extras, chosen)
				end
				chosen = spane
			elseif not chosen then
				chosen = spane
			else
				table.insert(extras, spane)
			end
		end
	end

	for _, ex in ipairs(extras) do
		painted_fp[ex] = nil
		opened_at_ms[ex] = nil
		persisted.owned_panes[tostring(ex)] = nil
		pcall(function()
			cx.layout:close(ex)
		end)
	end
	return chosen
end

local function is_sidebar_at_root_edge(lay: TabLayout?, spane: number, side: "left" | "right"): (boolean, number?)
	if not lay or not lay.root or lay.root.split ~= "right" then
		return false, nil
	end
	local cur: TabTree? = lay.root
	local share = 1.0
	local depth = 0
	while cur and depth < 8 do
		depth += 1
		if type(cur.pane) == "number" then
			if cur.pane == spane and depth > 1 then
				return true, share
			end
			return false, nil
		end
		if cur.split ~= "right" then
			return false, nil
		end
		local r = if type(cur.ratio) == "number" then cur.ratio else 0.5
		if side == "left" then
			share = share * r
			cur = cur[1]
		else
			share = share * (1.0 - r)
			cur = cur[2]
		end
	end
	return false, nil
end

local function match_ratio(cx: WindowCx, spane: number, tab_id: number, side: "left" | "right", target_ratio: number)
	local resize_dir: Dir = if side == "left" then "right" else "left"
	for step = 1, 5 do
		local ok, lay = pcall(function()
			return cx.session:layout(tab_id)
		end)
		if not ok or not lay then
			break
		end
		local at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
		if not at_edge or not cur_share then
			break
		end
		local diff = target_ratio - cur_share
		if math.abs(diff) <= 0.012 then
			synced_tab_ratio[tab_id] = cur_share
			break
		end
		local cols = persisted.cols_est
		local cells = math.floor(diff * cols + (if diff >= 0 then 0.5 else -0.5))
		if cells == 0 then
			cells = if diff > 0 then 1 else -1
		end
		local moved_ok, moved = pcall(function()
			return cx.layout:resize(spane, resize_dir, cells)
		end)
		if not moved_ok or not moved then
			synced_tab_ratio[tab_id] = cur_share
			break
		end
		local ok2, lay2 = pcall(function()
			return cx.session:layout(tab_id)
		end)
		if ok2 and lay2 then
			local ok_edge2, new_share = is_sidebar_at_root_edge(lay2, spane, side)
			if ok_edge2 and new_share then
				local actual_delta = new_share - cur_share
				if math.abs(actual_delta) > 0.005 then
					persisted.cols_est = clamp(math.abs(cells / actual_delta), 60, 600)
				end
				synced_tab_ratio[tab_id] = new_share
				if math.abs(target_ratio - new_share) <= 0.012 then
					break
				end
			end
		end
	end
end

local function edge_user_leaf(node: TabTree?, side: "left" | "right", spane: number): number?
	if not node then
		return nil
	end
	if type(node.pane) == "number" then
		return if node.pane ~= spane then node.pane else nil
	end
	local first_idx = if node.split == "right" and side == "right" then 2 else 1
	local second_idx = if first_idx == 1 then 2 else 1
	return edge_user_leaf(node[first_idx], side, spane) or edge_user_leaf(node[second_idx], side, spane)
end

local function place_sidebar_at_edge(
	cx: WindowCx,
	spane: number,
	tab_id: number,
	side: "left" | "right",
	target_ratio: number
)
	local cur_tab = cx.session:tab_of(spane)
	local moved_tabs = false
	if cur_tab ~= tab_id then
		local ok_m = pcall(function()
			cx.layout:move_to_tab(spane, tab_id, { focus = false })
		end)
		if not ok_m then
			return
		end
		moved_tabs = true
		synced_tab_ratio[tab_id] = nil
	end

	local ok_l, lay = pcall(function()
		return cx.session:layout(tab_id)
	end)
	if not ok_l or not lay then
		return
	end

	local at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
	if not at_edge then
		local target_leaf = edge_user_leaf(lay.root, side, spane)
		if target_leaf then
			pcall(function()
				cx.layout:move(spane, target_leaf, side, { focus = false })
			end)
		end
		ok_l, lay = pcall(function()
			return cx.session:layout(tab_id)
		end)
		at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
		synced_tab_ratio[tab_id] = nil
	end

	if at_edge and cur_share then
		if math.abs(cur_share - target_ratio) > 0.015 then
			match_ratio(cx, spane, tab_id, side, target_ratio)
		end
	end
end

local function refocus_terminal(cx: WindowCx, tab_id: number?, owned: { [number]: boolean })
	local f = cx.session:focused()
	if f and not owned[f] then
		local ftab = cx.session:tab_of(f)
		if ftab then
			last_user_pane_by_tab[ftab] = f
		end
		return
	end
	local t_id = tab_id or (if f then cx.session:tab_of(f) else nil)
	if not t_id then
		return
	end
	local u = first_user_pane(cx, t_id, owned)
	if u then
		last_user_pane_by_tab[t_id] = u
		pcall(function()
			cx.layout:focus(u)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Core Sync & Render Entrypoint
-- ---------------------------------------------------------------------------
local function sync_and_render(cx: WindowCx, force_paint: boolean?)
	if busy_lock then
		return
	end
	busy_lock = true

	local ok, err = pcall(function()
		ensure_status_bar(cx)

		if not persisted.visible then
			close_all_sidebars(cx)
			return
		end
		local ok_cs, cur_sess = pcall(function()
			return cx.sessions:current()
		end)
		local active_sess_id = if ok_cs and cur_sess then cur_sess.id else nil
		local active_host_id = if ok_cs and cur_sess then cur_sess.host else 0

		close_stale_canvases(cx, active_host_id)
		local owned = owned_canvases(cx)

		-- Clean up any orphan sidebar-only tab left behind after closing a tab's last terminal
		cleanup_orphan_sidebar_tabs(cx, owned, active_sess_id)
		owned = owned_canvases(cx)
		-- If current session has 0 tabs (e.g. empty session), open a default tab so the sidebar can mount
		if active_sess_id then
			local ok_t, tlist = pcall(function()
				return cx.session:tabs()
			end)
			local sess_tab_count = 0
			if ok_t and type(tlist) == "table" then
				for _, t in ipairs(tlist) do
					if t.session == active_sess_id then
						sess_tab_count += 1
					end
				end
			end
			if sess_tab_count == 0 then
				pcall(function()
					cx.layout:new_tab(nil, { focus = true })
				end)
				owned = owned_canvases(cx)
			end
		end

		local data = collect_data(cx)
		local tab_id = data.active_tab_id
		if not tab_id then
			return
		end

		local user_pane = first_user_pane(cx, tab_id, data.owned)
		if not user_pane then
			-- Only sidebar in the only tab of this session: split a terminal pane beside it
			local all_p = tab_all_panes(cx, tab_id)
			if #all_p > 0 then
				local term_dir: Dir = if persisted.side == "left" then "right" else "left"
				local new_p = cx.layout:split(all_p[1], term_dir, nil, { focus = true })
				if new_p then
					user_pane = new_p
					last_user_pane_by_tab[tab_id] = new_p
				end
			end
		end
		if not user_pane then
			return
		end

		local spane = find_host_sidebar(cx, active_host_id, tab_id, data.owned)
		local view, dock = build_view(data)
		local fp = build_fingerprint(data)

		if not spane then
			local opened_pane, open_err = cx.canvas:open({
				title = SIDEBAR_TITLE,
				about = SIDEBAR_ABOUT,
				how = "beside",
				target = user_pane,
				dir = persisted.side,
				ratio = persisted.ratio,
				focus = false,
				view = view,
				dock = dock,
			})
			if not opened_pane then
				tern.log.debug("sidebar2: canvas:open skipped:", tostring(open_err))
				return
			end
			spane = opened_pane
			opened_at_ms[spane] = tern.now()
			persisted.owned_panes[tostring(spane)] = true
			save_state()
			painted_fp[spane] = fp
			place_sidebar_at_edge(cx, spane, tab_id, persisted.side, persisted.ratio)
			-- Schedule fast follow-up hydrations for remote SSH hosts where tern.canvas starts asynchronously
			for _, delay_ms in ipairs({ 150, 400, 900 }) do
				tern.timer(delay_ms, function(timer_cx: WindowCx?)
					if timer_cx and not busy_lock and persisted.visible then
						sync_and_render(timer_cx, true)
					end
				end)
			end
		else
			place_sidebar_at_edge(cx, spane, tab_id, persisted.side, persisted.ratio)
			if force_paint or painted_fp[spane] ~= fp or needs_hydration(cx, spane) then
				cx.canvas:set(spane, {
					title = SIDEBAR_TITLE,
					about = SIDEBAR_ABOUT,
					view = view,
					dock = dock,
				})
				painted_fp[spane] = fp
			end
		end

		refocus_terminal(cx, tab_id, owned_canvases(cx))
		last_active_session_id = data.active_session_id
		last_active_tab_id = tab_id
	end)

	busy_lock = false
	if not ok then
		tern.log.warn("sidebar2 sync error:", tostring(err))
	end
	pcall(tern.chrome.refresh)
end

-- ---------------------------------------------------------------------------
-- Show / Hide / Flip Side / Kanban Group Actions
-- ---------------------------------------------------------------------------
local function set_sidebar_visible(cx: WindowCx, visible: boolean)
	persisted.visible = visible
	if not visible then
		picked_skey = nil
	end
	save_state()
	ensure_status_bar(cx)
	if not visible then
		close_all_sidebars(cx)
		pcall(tern.chrome.refresh)
	else
		sync_and_render(cx, true)
	end
end

local function toggle_sidebar(cx: WindowCx)
	set_sidebar_visible(cx, not persisted.visible)
end

local function flip_sidebar_side(cx: WindowCx)
	persisted.side = if persisted.side == "left" then "right" else "left"
	save_state()
	table.clear(synced_tab_ratio)
	close_all_sidebars(cx)
	if persisted.visible then
		sync_and_render(cx, true)
	end
end

local function set_session_group(cx: WindowCx, skey: string, group: GroupId, manual: boolean)
	if not GROUP_BY_ID[group] then
		return
	end
	persisted.groups[skey] = group
	if manual then
		persisted.manual_groups[skey] = true
	end
	picked_skey = nil
	save_state()
	sync_and_render(cx, true)
end

local function cycle_session_group(cx: WindowCx, skey: string)
	local cur: GroupId = persisted.groups[skey] or "todo"
	local spec = GROUP_BY_ID[cur] or GROUPS[1]
	set_session_group(cx, skey, spec.next_id, true)
end

local function open_move_modal(cx: WindowCx)
	local data = collect_data(cx)
	local items: { PickItem } = {}
	for _, s in ipairs(data.sessions) do
		local cur_spec = GROUP_BY_ID[s.group] or GROUPS[1]
		for _, g in ipairs(GROUPS) do
			table.insert(items, {
				label = s.host_name .. " / " .. s.name .. "  →  " .. g.label,
				detail = "Current: " .. cur_spec.label,
				group = g.label,
				icon = "kanban",
				current = (s.group == g.id),
				skey = s.skey,
				target_group = g.id,
			})
		end
	end
	if #items == 0 then
		return
	end
	cx:pick({
		placeholder = "Move Host / Session to TODO, Processing, or DONE…",
		icon = "kanban",
		action = "move",
		items = items,
	}):next(function(choice, _err, pick_cx)
		if choice and pick_cx and type(choice.skey) == "string" and type(choice.target_group) == "string" then
			set_session_group(pick_cx, choice.skey, choice.target_group :: GroupId, true)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Canvas Action Dispatcher
-- ---------------------------------------------------------------------------
local function parse_action(ev: CanvasAction): (string, string)
	local act = ev.act or ""
	local val = ev.value or ""
	local eq = string.find(act, "=", 1, true)
	if eq then
		return string.sub(act, 1, eq - 1), string.sub(act, eq + 1)
	end
	return act, val
end

local function focus_session_tab_pane(cx: WindowCx, sess_id: number?, tab_id: number?, pane_id: number?)
	local owned = owned_canvases(cx)
	local ok_cs, cur = pcall(function()
		return cx.sessions:current()
	end)
	if sess_id and (not ok_cs or not cur or cur.id ~= sess_id) then
		pcall(function()
			cx.sessions:switch(sess_id)
		end)
	end
	if pane_id and not owned[pane_id] then
		if tab_id then
			last_user_pane_by_tab[tab_id] = pane_id
		end
		pcall(function()
			cx.layout:focus(pane_id)
		end)
	elseif tab_id then
		local u = first_user_pane(cx, tab_id, owned)
		if u then
			last_user_pane_by_tab[tab_id] = u
			pcall(function()
				cx.layout:focus(u)
			end)
		end
	end
	sync_and_render(cx, false)
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= tern.plugin.id then
		return nil
	end
	local cmd, val = parse_action(ev)

	if cmd == "hide_sidebar" then
		set_sidebar_visible(cx, false)
		return true
	elseif cmd == "flip_side" then
		flip_sidebar_side(cx)
		return true
	elseif cmd == "refresh" then
		sync_and_render(cx, true)
		return true
	elseif cmd == "fold_all" then
		local data = collect_data(cx)
		local any_open = false
		for _, s in ipairs(data.sessions) do
			if not persisted.fold_sessions[s.skey] then
				any_open = true
				break
			end
		end
		for _, s in ipairs(data.sessions) do
			persisted.fold_sessions[s.skey] = any_open
		end
		save_state()
		sync_and_render(cx, true)
		return true
	elseif cmd == "fold_group" then
		persisted.fold_groups[val] = not (persisted.fold_groups[val] == true)
		save_state()
		sync_and_render(cx, true)
		return true
	elseif cmd == "fold_sess" then
		persisted.fold_sessions[val] = not (persisted.fold_sessions[val] == true)
		save_state()
		sync_and_render(cx, true)
		return true
	elseif cmd == "fold_tab" then
		persisted.fold_tabs[val] = not (persisted.fold_tabs[val] == true)
		save_state()
		sync_and_render(cx, true)
		return true
	elseif cmd == "pick" then
		picked_tab_id = nil
		picked_tab_sess = nil
		if picked_skey == val then
			picked_skey = nil
		else
			picked_skey = val
		end
		sync_and_render(cx, true)
		return true
	elseif cmd == "pick_tab" then
		picked_skey = nil
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local sid = tonumber(s_str)
		local tid = tonumber(t_str)
		if tid and sid then
			if picked_tab_id == tid then
				picked_tab_id = nil
				picked_tab_sess = nil
			else
				picked_tab_id = tid
				picked_tab_sess = sid
			end
		end
		sync_and_render(cx, true)
		return true
	elseif cmd == "drop_tab" then
		local target_pos = tonumber(val)
		if picked_tab_id and target_pos then
			local tid = picked_tab_id
			picked_tab_id = nil
			picked_tab_sess = nil
			pcall(function()
				cx.layout:order_tab(tid, target_pos)
			end)
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "tab_move" then
		local t_str, pos_str = string.match(val, "^(%d+):(%d+)$")
		local tid = tonumber(t_str)
		local target_pos = tonumber(pos_str)
		if tid and target_pos then
			picked_tab_id = nil
			picked_tab_sess = nil
			pcall(function()
				cx.layout:order_tab(tid, target_pos)
			end)
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "cancel_pick" then
		picked_skey = nil
		picked_tab_id = nil
		picked_tab_sess = nil
		sync_and_render(cx, true)
		return true
	elseif cmd == "drop_group" then
		if picked_skey and GROUP_BY_ID[val] then
			set_session_group(cx, picked_skey, val :: GroupId, true)
		end
		return true
	elseif cmd == "cycle_group" then
		cycle_session_group(cx, val)
		return true
	elseif cmd == "move_todo" then
		set_session_group(cx, val, "todo", true)
		return true
	elseif cmd == "move_doing" then
		set_session_group(cx, val, "doing", true)
		return true
	elseif cmd == "move_done" then
		set_session_group(cx, val, "done", true)
		return true
	elseif cmd == "move_modal" then
		open_move_modal(cx)
		return true
	elseif cmd == "focus_sess" then
		local sid = tonumber(val)
		if sid then
			focus_session_tab_pane(cx, sid, nil, nil)
		end
		return true
	elseif cmd == "focus_tab" then
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local sid = tonumber(s_str)
		local tid = tonumber(t_str)
		focus_session_tab_pane(cx, sid, tid, nil)
		return true
	elseif cmd == "focus_pane" then
		local s_str, t_str, p_str = string.match(val, "^(%d+):(%d+):(%d+)$")
		local sid = tonumber(s_str)
		local tid = tonumber(t_str)
		local pid = tonumber(p_str)
		focus_session_tab_pane(cx, sid, tid, pid)
		return true
	elseif cmd == "new_session" or cmd == "new_session_in" then
		local target_grp: GroupId = if GROUP_BY_ID[val] then (val :: GroupId) else "todo"
		cx:prompt({
			placeholder = "New session name (leave blank for auto)…",
			icon = "kanban",
			action = "create",
		}):next(function(name, _err, prompt_cx)
			if name == nil or not prompt_cx then
				return
			end
			local trimmed = string.gsub(name, "^%s*(.-)%s*$", "%1")
			local ok_c, created = pcall(function()
				if trimmed ~= "" then
					return prompt_cx.sessions:create({ name = trimmed })
				else
					return prompt_cx.sessions:create()
				end
			end)
			if ok_c and created then
				local ok_h, cur_h = pcall(function()
					return prompt_cx.hosts:current()
				end)
				local hname = if ok_h and cur_h and cur_h.name ~= "" then cur_h.name else "local"
				local skey = hname .. "::" .. created.name
				persisted.groups[skey] = target_grp
				persisted.manual_groups[skey] = true
				save_state()
				sync_and_render(prompt_cx, true)
			end
		end)
		return true
	elseif cmd == "new_tab" then
		pcall(function()
			cx.layout:new_tab(nil, { focus = true })
		end)
		sync_and_render(cx, true)
		return true
	elseif cmd == "new_tab_in" then
		local sid = tonumber(val)
		if sid then
			pcall(function()
				cx.sessions:switch(sid)
				cx.layout:new_tab(nil, { focus = true })
			end)
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "rename_sess" then
		local sid = tonumber(val)
		if sid then
			cx:prompt({
				placeholder = "Rename session…",
				icon = "kanban",
				action = "rename",
			}):next(function(new_name, _err, prompt_cx)
				if new_name and new_name ~= "" and prompt_cx then
					pcall(function()
						prompt_cx.sessions:rename(sid, new_name)
					end)
					sync_and_render(prompt_cx, true)
				end
			end)
		end
		return true
	elseif cmd == "rename_tab" then
		local tid = tonumber(val)
		if tid then
			cx:prompt({
				placeholder = "Rename tab…",
				icon = "kanban",
				action = "rename",
			}):next(function(new_name, _err, prompt_cx)
				if new_name ~= nil and prompt_cx then
					pcall(function()
						prompt_cx.layout:name_tab(tid, if new_name ~= "" then new_name else nil)
					end)
					sync_and_render(prompt_cx, true)
				end
			end)
		end
		return true
	elseif cmd == "close_tab" then
		local tid = tonumber(val)
		if tid then
			local owned = owned_canvases(cx)
			for _, pid in ipairs(tab_all_panes(cx, tid)) do
				if not owned[pid] then
					pcall(function()
						cx.layout:close(pid)
					end)
				end
			end
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "split_right" then
		local pid = tonumber(val)
		if pid then
			pcall(function()
				cx.layout:split(pid, "right", nil, { focus = true })
			end)
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "split_down" then
		local pid = tonumber(val)
		if pid then
			pcall(function()
				cx.layout:split(pid, "down", nil, { focus = true })
			end)
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "close_pane" then
		local pid = tonumber(val)
		if pid then
			pcall(function()
				cx.layout:close(pid)
			end)
			sync_and_render(cx, true)
		end
		return true
	end

	return true
end)

-- ---------------------------------------------------------------------------
-- Always-Accessible Show/Hide Toggle Surfaces (Status Bar, Files Button, Commands, Keybind)
-- ---------------------------------------------------------------------------
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if persisted.visible then
		return {
			{
				text = "Kanban: ON · " .. current_stage_label,
				icon = "kanban",
				tone = current_stage_tone,
				command = "plugin.sidebar2.toggle",
			},
		}
	else
		return {
			{
				text = "Kanban: OFF",
				icon = "kanban",
				tone = "muted",
				command = "plugin.sidebar2.toggle",
			},
		}
	end
end)

tern.files.button({
	id = "toggle",
	title = "Toggle Kanban Sidebar (Ctrl+Alt+B)",
	icon = "kanban",
	run = function(_files: FilesInfo, cx: WindowCx)
		toggle_sidebar(cx)
	end,
})

tern.command({
	id = "toggle",
	title = "Kanban Sidebar: Show / Hide Toggle",
	icon = "kanban",
	keys = { "ctrl+alt+b", "cmd+alt+b" },
	run = function(cx: WindowCx)
		toggle_sidebar(cx)
	end,
})

tern.command({
	id = "show",
	title = "Kanban Sidebar: Show",
	icon = "kanban",
	run = function(cx: WindowCx)
		set_sidebar_visible(cx, true)
	end,
})

tern.command({
	id = "hide",
	title = "Kanban Sidebar: Hide",
	icon = "kanban",
	run = function(cx: WindowCx)
		set_sidebar_visible(cx, false)
	end,
})

tern.command({
	id = "flip_side",
	title = "Kanban Sidebar: Switch Left / Right Side",
	icon = "kanban",
	run = function(cx: WindowCx)
		flip_sidebar_side(cx)
	end,
})

tern.command({
	id = "move_session",
	title = "Kanban Sidebar: Move Session to TODO / Processing / DONE…",
	icon = "kanban",
	run = function(cx: WindowCx)
		open_move_modal(cx)
	end,
})

pcall(function()
	tern.bind("ctrl+alt+b", "plugin.sidebar2.toggle")
	tern.bind("cmd+alt+b", "plugin.sidebar2.toggle")
end)

-- ---------------------------------------------------------------------------
-- Lifecycle Hooks & 250ms Session/Tab Watcher Tick
-- ---------------------------------------------------------------------------
local function start_watcher()
	local function step(cx: WindowCx?)
		if cx and not busy_lock then
			if persisted.visible then
				local ok_cs, cur_s = pcall(function()
					return cx.sessions:current()
				end)
				local cur_sid = if ok_cs and cur_s then cur_s.id else nil
				local f = cx.session:focused()
				local cur_tid = if f then cx.session:tab_of(f) else nil
				local owned = owned_canvases(cx)
				if f and owned[f] then
					refocus_terminal(cx, cur_tid, owned)
				end
				if cur_sid ~= last_active_session_id or (cur_tid and cur_tid ~= last_active_tab_id) then
					sync_and_render(cx, false)
				else
					local data = collect_data(cx)
					local fp = build_fingerprint(data)
					local cur_host = if ok_cs and cur_s then cur_s.host else 0
					local spane = find_host_sidebar(cx, cur_host, data.active_tab_id, data.owned)
					if not spane or painted_fp[spane] ~= fp or needs_hydration(cx, spane) then
						sync_and_render(cx, true)
					elseif data.active_tab_id then
						place_sidebar_at_edge(cx, spane, data.active_tab_id, persisted.side, persisted.ratio)
					end
				end
			end
		end
		tern.timer(250, step)
	end
	tern.timer(250, step)
end

tern.on("window_start", function(cx: WindowCx)
	ensure_status_bar(cx)
	sync_and_render(cx, true)
	start_watcher()
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if busy_lock then
		return
	end
	local owned = owned_canvases(cx)
	if owned[ev.pane] then
		refocus_terminal(cx, ev.tab, owned)
	else
		last_user_pane_by_tab[ev.tab] = ev.pane
	end
	if persisted.visible then
		sync_and_render(cx, false)
	end
end)

for _, ev_name in ipairs({
	"tab_created",
	"tab_closed",
	"pane_created",
	"pane_closed",
	"command_started",
	"command_finished",
	"title",
	"agent_state",
	"agent_finished",
	"session_ended",
}) do
	tern.on(ev_name, function(_ev: any, cx: WindowCx)
		if not busy_lock and persisted.visible then
			sync_and_render(cx, false)
		end
	end)
end
