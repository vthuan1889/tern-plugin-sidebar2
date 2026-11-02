-- sidebar2/window.luau
-- Fixed Kanban Sidebar (TODO / WORKING / REVIEW / PAUSED / STUCK / DONE) with 3-Level Hierarchy:
--   Level 1: Host + Session name (movable between every stage)
--   Level 2: Tabs in each session
--   Level 3: Panes in each tab

local ui = tern.ui

local SIDEBAR_TITLE = "Kanban"
local SIDEBAR_ABOUT = "Fixed Kanban sidebar (TODO / WORKING / REVIEW / PAUSED / STUCK / DONE) organizing Host + Session, Tabs, and Panes."
-- Width until a divider is dragged; from then on the dragged ratio is what every session gets.
local FIXED_SIDEBAR_RATIO = 0.20
local MIN_SIDEBAR_RATIO = 0.08
local MAX_SIDEBAR_RATIO = 0.60

type GroupId = "todo" | "doing" | "review" | "paused" | "stuck" | "done"

type GroupSpec = {
	id: GroupId,
	label: string,
	short: string,
	tone: string,
	icon: string,
	next_id: GroupId,
}

local GROUPS: { GroupSpec } = {
	{ id = "todo", label = "TODO", short = "TODO", tone = "info", icon = "inbox", next_id = "doing" },
	{ id = "doing", label = "WORKING", short = "WORKING", tone = "warning", icon = "activity", next_id = "review" },
	{ id = "review", label = "REVIEW", short = "REVIEW", tone = "info", icon = "eye", next_id = "paused" },
	{ id = "paused", label = "PAUSED", short = "PAUSED", tone = "neutral", icon = "pause", next_id = "stuck" },
	{ id = "stuck", label = "STUCK", short = "STUCK", tone = "warning", icon = "warn", next_id = "done" },
	{ id = "done", label = "DONE", short = "DONE", tone = "success", icon = "check", next_id = "todo" },
}

local GROUP_BY_ID: { [ string ]: GroupSpec } = {}
for _, g in ipairs(GROUPS) do
	GROUP_BY_ID[g.id] = g
end

type BadgeKey = "total" | "running" | "idle" | "hide_zero"

type BadgeVis = {
	total: boolean,
	running: boolean,
	idle: boolean,
	-- Hide a count badge whose value is 0 instead of showing "0".
	hide_zero: boolean,
}

type PersistedState = {
	visible: boolean,
	side: "left" | "right",
	ratio: number,
	cols_est: number,
	groups: { [string]: GroupId },
	manual_groups: { [string]: boolean },
	session_order: { [string]: number },
	fold_groups: { [string]: boolean },
	fold_sessions: { [string]: boolean },
	fold_tabs: { [string]: boolean },
	marked_tabs: { [string]: boolean },
	owned_panes: { [string]: boolean },
	badge_vis: BadgeVis,
	stage_vis: { [string]: boolean },
	hide_empty: boolean,
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
	local ratio = if type(tbl.ratio) == "number"
		then clamp(tbl.ratio, MIN_SIDEBAR_RATIO, MAX_SIDEBAR_RATIO)
		else FIXED_SIDEBAR_RATIO
	local cols_est = if type(tbl.cols_est) == "number" then clamp(tbl.cols_est, 60, 600) else 180
	local raw_bv = if type(tbl.badge_vis) == "table" then tbl.badge_vis else {}
	local badge_vis: BadgeVis = {
		total = if type(raw_bv.total) == "boolean" then raw_bv.total else true,
		running = if type(raw_bv.running) == "boolean" then raw_bv.running else true,
		idle = if type(raw_bv.idle) == "boolean" then raw_bv.idle else true,
		hide_zero = if type(raw_bv.hide_zero) == "boolean" then raw_bv.hide_zero else false,
	}
	return {
		visible = visible,
		side = side,
		ratio = ratio,
		cols_est = cols_est,
		groups = if type(tbl.groups) == "table" then tbl.groups else {},
		manual_groups = if type(tbl.manual_groups) == "table" then tbl.manual_groups else {},
		session_order = if type(tbl.session_order) == "table" then tbl.session_order else {},
		fold_groups = if type(tbl.fold_groups) == "table" then tbl.fold_groups else {},
		fold_sessions = if type(tbl.fold_sessions) == "table" then tbl.fold_sessions else {},
		fold_tabs = if type(tbl.fold_tabs) == "table" then tbl.fold_tabs else {},
		marked_tabs = if type(tbl.marked_tabs) == "table" then tbl.marked_tabs else {},
		-- Ignored on load: another window writes its own pane ids here, and trusting them made this
		-- window claim, move or close a canvas it does not own.
		owned_panes = {},
		badge_vis = badge_vis,
		-- Absent means visible: a stage only hides once its pill is switched off.
		stage_vis = if type(tbl.stage_vis) == "table" then tbl.stage_vis else {},
		hide_empty = tbl.hide_empty == true,
	}
end

local persisted: PersistedState = load_state()

local function save_state()
	pcall(tern.kv.set, "state", persisted)
end

-- Runtime state (per window VM)
local busy_lock = false
-- A sync that arrives mid-paint is dropped, and a hover frame dropped that way leaves the drag
-- anchor line stale until the cursor crosses another slot; re-run it once the paint finishes.
local render_pending = false
-- Remote daemons cannot host canvases (Tern 0.9.9: `canvas:open` returns a pane id, then every
-- `set` fails with "pane is not a canvas"), which left a blank strip nobody could remove. A host
-- that refused is remembered by the Tern version it refused with, and retried only when that
-- version changes, so no pane is respawned on every sync.
local canvas_refused: { [number]: string } = {}
local last_refusal_warn_s = 0
local picked_skey: string? = nil
local hover_group: GroupId? = nil
local hover_sess_pos: number? = nil
local picked_tab_id: number? = nil
local picked_tab_sess: number? = nil
local hover_tab_pos: number? = nil
local last_drag_active = false
local last_drag_end_ms = 0
local last_drop_seq = 0
local dom_map_seq = 0
local last_dom_map_fp = ""
local helper_running = false
local last_helper_check_ms = 0
local painted_fp: { [number]: string } = {}
-- Per-section fingerprints of the last paint, so a sync can patch only the changed columns.
-- Absent for a pane that must be repainted whole (`painted_fp` is nil then).
local painted_sec_fp: { [number]: { [string]: string } } = {}
local pane_notif: { [number]: "waiting" | "done" | "error" } = {}
local prev_pane_busy: { [number]: boolean } = {}
local known_agents: { [number]: boolean } = {}
local ack_alerts: { [number]: boolean } = {}
local closing_internally: { [number]: boolean } = {}
local active_sidebar_pane: number? = nil

do
	local ok_dd, dd = pcall(tern.kv.get, "drag_drop")
	if ok_dd and type(dd) == "table" and type(dd.seq) == "number" then
		last_drop_seq = dd.seq
	end
	pcall(tern.kv.set, "drag_state", { active = false })
end

local function ensure_drag_helper(force: boolean?)
	if helper_running or not persisted.visible then
		return
	end
	local now = tern.now()
	if not force and last_helper_check_ms > 0 and (now - last_helper_check_ms) < 3500 then
		return
	end
	last_helper_check_ms = now
	helper_running = true
	local script_path = tern.plugin.dir .. "/drag_helper.py"
	local kv_path = tern.plugin.data .. "/kv.json"
	local ok, err = pcall(function()
		tern.process.run({ "python", script_path, kv_path }, { cwd = tern.plugin.dir }, function(_res, _timer_cx)
			helper_running = false
		end)
	end)
	if not ok then
		helper_running = false
		tern.log.warn("sidebar2 drag_helper spawn failed:", tostring(err))
	end
end
local opened_at_ms: { [number]: number } = {}
local synced_tab_ratio: { [number]: number } = {}
local last_user_pane_by_tab: { [number]: number } = {}
-- Focus order for "start in" tie-breaks: higher means focused more recently.
local focus_rank: { [number]: number } = {}
local focus_rank_seq = 0
local last_active_session_id: number? = nil
local last_active_tab_id: number? = nil
local last_active_tab_by_session: { [number]: number } = {}
local current_stage_label = "TODO"
local current_stage_tone = "info"
local badge_cfg_open = false
local stage_cfg_open = false

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
			-- Identity only: pane ids saved by another window's copy of this plugin must never make a
			-- foreign pane ours (that is how a sidebar got moved or closed from the wrong window).
			local is_canvas = (p.kind == "canvas" or p.program == "tern.canvas" or p.block == "tern.canvas" or p.block == "plugin.tern.canvas")
			if is_canvas and (p.title == SIDEBAR_TITLE or p.title == "Canvas" or p.title == "TestRemoteCanvas") then
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
		local existing: { [string]: boolean } = {}
		for _, p in ipairs(plist) do
			local pkey = tostring(p.pane)
			existing[pkey] = true
			if (not on_host or on_host[p.pane]) and not live[p.pane] then
				-- `tern.now()` counts seconds. A canvas that no runtime registered yet is still
				-- hydrating: only give up on it once the grace passed AND it sits in no tab.
				local opened_t = opened_at_ms[p.pane]
				local cooling = opened_t ~= nil and (now - opened_t) < 2.5
				if not cooling and cx.session:tab_of(p.pane) == nil then
					local is_canvas = (p.kind == "canvas" or p.program == "tern.canvas" or p.block == "tern.canvas" or p.block == "plugin.tern.canvas")
					if persisted.owned_panes[pkey] or (is_canvas and (p.title == SIDEBAR_TITLE or p.title == "Canvas" or p.title == "TestRemoteCanvas")) then
						persisted.owned_panes[pkey] = nil
						painted_fp[p.pane] = nil
						opened_at_ms[p.pane] = nil
						closing_internally[p.pane] = true
						dirty = true
						pcall(function()
							cx.layout:close(p.pane)
						end)
					end
				end
			end
		end
		for pkey, _ in pairs(persisted.owned_panes) do
			if not existing[pkey] then
				persisted.owned_panes[pkey] = nil
				dirty = true
			end
		end
	end
	if dirty then
		save_state()
	end
end

-- Forget a pane the canvas runtime refuses and close it, so no blank strip is left behind.
local function drop_sidebar_pane(cx: WindowCx, spane: number)
	painted_fp[spane] = nil
	painted_sec_fp[spane] = nil
	opened_at_ms[spane] = nil
	persisted.owned_panes[tostring(spane)] = nil
	closing_internally[spane] = true
	active_sidebar_pane = nil
	save_state()
	pcall(function()
		cx.layout:close(spane)
	end)
end

local function canvas_host_ready(host_id: number, tern_version: string): boolean
	return canvas_refused[host_id] ~= tern_version
end

local function refuse_canvas_on_host(host_id: number, tern_version: string)
	if tern_version ~= "" then
		canvas_refused[host_id] = tern_version
	end
end

local function needs_hydration(cx: WindowCx, spane: number): boolean
	local opened_t = opened_at_ms[spane]
	if opened_t and (tern.now() - opened_t) < 2.5 then
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

-- Nearest tab of the same session that still holds a user pane: previous tab, then next, then distance.
local function find_best_sibling_tab(
	cx: WindowCx,
	sess_id: number?,
	closing_tid: number,
	owned: { [number]: boolean }
): number?
	if not sess_id then
		return nil
	end
	local ok_t, tlist = pcall(function()
		return cx.session:tabs()
	end)
	if not ok_t or type(tlist) ~= "table" then
		return nil
	end
	local sess_tabs: { TabInfo } = {}
	for _, t in ipairs(tlist) do
		if t.session == sess_id then
			table.insert(sess_tabs, t)
		end
	end
	table.sort(sess_tabs, function(a, b)
		if a.position ~= b.position then
			return a.position < b.position
		end
		return a.id < b.id
	end)
	local closing_idx = 0
	for idx, t in ipairs(sess_tabs) do
		if t.id == closing_tid then
			closing_idx = idx
			break
		end
	end
	if closing_idx == 0 then
		return nil
	end
	local best: number? = nil
	local best_score = math.huge
	for idx, t in ipairs(sess_tabs) do
		if t.id ~= closing_tid then
			local score = math.abs(idx - closing_idx) * 2 + (if idx > closing_idx then 1 else 0)
			if score < best_score and first_user_pane(cx, t.id, owned) ~= nil then
				best = t.id
				best_score = score
			end
		end
	end
	return best
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
type ItemStatus = "none" | "read" | "unread" | "working"

local STATUS_PRIO: { [ItemStatus]: number } = {
	none = 0,
	read = 1,
	unread = 2,
	working = 3,
}

local function merge_status(a: ItemStatus, b: ItemStatus): ItemStatus
	if (STATUS_PRIO[b] or 0) > (STATUS_PRIO[a] or 0) then
		return b
	end
	return a
end

-- Program/command name -> Tern icon; the first match wins.
local AGENT_ICONS: { { string } } = {
	{ "opencode", "provider-opencode" },
	{ "omp", "app-omp" },
	{ "claude", "app-claude" },
	{ "codex", "app-codex" },
	{ "hermes", "app-hermes" },
	{ "gemini", "mi-gemini-ai" },
	{ "copilot", "mi-copilot" },
	{ "cursor", "mi-cursor" },
	{ "cline", "mi-cline" },
	{ "devin", "provider-devin" },
	{ "kilo", "provider-kilo" },
	{ "kimi", "provider-kimi-code" },
	{ "qwen", "provider-qwen-portal" },
	{ "deepseek", "provider-deepseek" },
	{ "aider", "sparkle" },
	{ "goose", "sparkle" },
	{ "carly", "sparkle" },
}

local function agent_icon_from_text(s: string?): string?
	if not s or s == "" then
		return nil
	end
	local lower = string.lower(s)
	for _, pair in ipairs(AGENT_ICONS) do
		-- Word-bounded so "composer" and "prompt" do not read as omp.
		if string.find(lower, "%f[%w]" .. pair[1] .. "%f[%W]") then
			return pair[2]
		end
	end
	return nil
end

local function is_ai_agent_pane(pinfo: PaneInfo, astate: string?, acmd: string?, tab_prog: string?): boolean
	if astate ~= nil or pinfo.kind == "agent" or pinfo.kind == "carly" then
		return true
	end
	if agent_icon_from_text(pinfo.program) or agent_icon_from_text(acmd) or agent_icon_from_text(tab_prog) then
		return true
	end
	if pinfo.running and agent_icon_from_text(pinfo.running.line) then
		return true
	end
	local ttl = pinfo.title or ""
	if string.find(ttl, "✦", 1, true) then
		return true
	end
	return false
end
type PaneEntry = {
	id: number,
	kind: string,
	title: string,
	sub: string?,
	busy: boolean,
	err: boolean,
	status: ItemStatus,
	focused: boolean,
	is_agent: boolean,
	icon: string,
}

type TabEntry = {
	id: number,
	session_id: number,
	pos: number,
	title: string,
	busy: boolean,
	status: ItemStatus,
	current: boolean,
	icon: string,
	has_agent: boolean,
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
	pos: number,
	busy: boolean,
	status: ItemStatus,
	tabs: { TabEntry },
	pane_count: number,
}

type GroupAgentCounts = {
	total: number,
	running: number,
	idle: number,
}

type CollectedData = {
	sessions: { SessionEntry },
	by_group: { [GroupId]: { SessionEntry } },
	by_skey: { [string]: SessionEntry },
	group_counts: { [GroupId]: GroupAgentCounts },
	active_session_id: number?,
	active_tab_id: number?,
	focused_pane: number?,
	owned: { [number]: boolean },
}

-- Title glyphs an AI agent prefixes its own terminal title with: Nerd Font private-use icons and "✦".
local function strip_leading_title_icon(s: string): string
	local out = string.gsub(s, "^%s+", "")
	while out ~= "" do
		local ok, cp = pcall(utf8.codepoint, out, 1)
		if not ok then
			break
		end
		local glyph = (cp >= 0xE000 and cp <= 0xF8FF)
			or (cp >= 0xF0000 and cp <= 0xFFFFD)
			or (cp >= 0x100000 and cp <= 0x10FFFD)
			or cp == 0x2726
		if not glyph then
			break
		end
		out = string.sub(out, (if cp < 0x80 then 1 elseif cp < 0x800 then 2 elseif cp < 0x10000 then 3 else 4) + 1)
		out = string.gsub(out, "^%s+", "")
	end
	return out
end

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

-- A tab shows its agent pane's icon: a busy one, else the focused one, else any.
local function tab_agent_icon_of(panes: { PaneEntry }): string?
	for _, p in ipairs(panes) do
		if p.is_agent and p.busy then
			return p.icon
		end
	end
	for _, p in ipairs(panes) do
		if p.is_agent and p.focused then
			return p.icon
		end
	end
	for _, p in ipairs(panes) do
		if p.is_agent then
			return p.icon
		end
	end
	return nil
end

-- Tern's own icon set (208 names) instead of emoji glyphs: they scale, tone and align with the theme.
local function resolve_pane_icon(pinfo: PaneInfo, is_agent: boolean, acmd: string?, tab_prog: string?): string
	if is_agent then
		local icon = agent_icon_from_text(acmd)
			or agent_icon_from_text(pinfo.running and pinfo.running.line)
			or agent_icon_from_text(pinfo.program)
			or agent_icon_from_text(tab_prog)
			or agent_icon_from_text(pinfo.last and pinfo.last.line)
			or agent_icon_from_text(pinfo.title)
		if icon then
			return icon
		end
		-- An agent block with nothing to name it runs omp; carly keeps the sparkle.
		return if pinfo.kind == "carly" then "sparkle" else "app-omp"
	end
	local kind = pinfo.kind or "terminal"
	if kind == "file" then
		return "file-code"
	elseif kind == "git" then
		return "branch"
	elseif kind == "browser" then
		return "globe"
	elseif kind == "database" then
		return "database"
	elseif kind == "notebook" then
		return "note"
	elseif kind == "board" then
		return "kanban"
	elseif kind == "procs" or kind == "profile" then
		return "cpu"
	elseif kind == "screen" then
		return "monitor"
	elseif kind == "canvas" then
		return "canvas"
	end
	return "terminal"
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
	local agent_cmd_by_pane: { [number]: string } = {}
	local ok_a, alist = pcall(function()
		return cx.agents:list()
	end)
	if ok_a and type(alist) == "table" then
		for _, a in ipairs(alist) do
			if type(a.pane) == "number" then
				if type(a.state) == "string" then
					agent_state_by_pane[a.pane] = a.state
				end
				if type(a.command) == "string" and a.command ~= "" then
					agent_cmd_by_pane[a.pane] = a.command
				end
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
			local remembered = last_active_tab_by_session[active_session_id]
			if remembered then
				for _, t in ipairs(raw_tabs_by_sess[active_session_id]) do
					if t.id == remembered then
						active_tab_id = remembered
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
		if active_tab_id then
			last_active_tab_by_session[active_session_id] = active_tab_id
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
	-- Every stage GROUPS defines needs a bucket; a missing one made the whole sidebar fail to build.
	local by_group: { [GroupId]: { SessionEntry } } = {}
	local by_skey: { [string]: SessionEntry } = {}
	local group_counts: { [GroupId]: GroupAgentCounts } = {}
	for _, g in ipairs(GROUPS) do
		by_group[g.id] = {}
		group_counts[g.id] = { total = 0, running = 0, idle = 0 }
	end
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
		local sess_status_kind: ItemStatus = "none"
		local sess_pane_count = 0
		local stabs = raw_tabs_by_sess[s.id] or {}

		for idx, t in ipairs(stabs) do
			local fb_panes = panes_by_tab_fallback[t.id]
			local ordered_ids: { number }
			if fb_panes and #fb_panes > 1 then
				ordered_ids = tab_all_panes(cx, t.id)
				if #ordered_ids == 0 then
					ordered_ids = fb_panes
				end
			else
				ordered_ids = fb_panes or {}
			end
			local seen_p: { [number]: boolean } = {}
			local pane_entries: { PaneEntry } = {}
			local tab_busy = false
			local tab_status_kind: ItemStatus = "none"
			local primary_user_title: string? = nil

			for _, pid in ipairs(ordered_ids) do
				if not seen_p[pid] and not owned[pid] then
					seen_p[pid] = true
					local pinfo = pane_info_by_id[pid]
					if pinfo then
						local astate = agent_state_by_pane[pid]
						local acmd = agent_cmd_by_pane[pid]
						-- Only a tab whose program names an agent tells its focused/only pane anything.
						local tab_prog = if t.pane == pid or #ordered_ids <= 1 then t.program else nil
						local is_agent = is_ai_agent_pane(pinfo, astate, acmd, tab_prog)
						local picon = resolve_pane_icon(pinfo, is_agent, acmd, tab_prog)
						local pbusy = if astate ~= nil
							then (astate == "working")
							else (pinfo.busy == true)
						local perr = (pinfo.error ~= nil)
							or (pinfo.last ~= nil and pinfo.last.status ~= 0)
							or (astate == "waiting_input")
						local is_visible_tab = is_cur_sess and (t.id == active_tab_id)
						local pfocused = (focused == pid)
							or (is_visible_tab and (last_user_pane_by_tab[t.id] == pid or last_user_pane_by_tab[t.id] == nil))
						local pviewed = pfocused or is_visible_tab
						if is_agent then
							known_agents[pid] = true
						end
						if pbusy then
							pane_notif[pid] = nil
							ack_alerts[pid] = false
							prev_pane_busy[pid] = true
						else
							if prev_pane_busy[pid] == true then
								prev_pane_busy[pid] = false
								if not pviewed then
									pane_notif[pid] = "done"
								end
							end
							if pinfo.alert ~= true then
								ack_alerts[pid] = false
							end
							if pviewed then
								pane_notif[pid] = nil
								if pinfo.alert == true then
									ack_alerts[pid] = true
								end
							end
						end
						local pstatus: ItemStatus = "none"
						if pbusy then
							pstatus = "working"
						elseif
							astate == "waiting_input"
							or (pinfo.alert == true and not ack_alerts[pid])
							or pane_notif[pid] ~= nil
						then
							pstatus = "unread"
						elseif known_agents[pid] then
							pstatus = "read"
						end
						local raw_title = if pinfo.title and pinfo.title ~= "" and pinfo.title ~= SIDEBAR_TITLE
							then pinfo.title
							elseif pinfo.program and pinfo.program ~= "" then pinfo.program
							else (pinfo.kind or "shell")
						-- The row draws the agent's icon itself, so drop the one the program put in its title.
						local stripped = strip_leading_title_icon(raw_title)
						if stripped ~= "" then
							raw_title = stripped
						end
						if not primary_user_title then
							primary_user_title = raw_title
						end
						local sub: string? = nil
						if pinfo.running and pinfo.running.line and pinfo.running.line ~= "" then
							sub = short_text(pinfo.running.line, 48)
						elseif astate and astate ~= "idle" then
							sub = astate
						end
						if pbusy then
							tab_busy = true
						end
						tab_status_kind = merge_status(tab_status_kind, pstatus)
						table.insert(pane_entries, {
							id = pid,
							kind = pinfo.kind or "terminal",
							title = short_text(raw_title, 90),
							sub = sub,
							busy = pbusy,
							err = perr,
							status = pstatus,
							focused = pfocused,
							is_agent = is_agent,
							icon = picon,
						})
					end
				end
			end

			sess_pane_count += #pane_entries
			if tab_busy then
				sess_busy = true
			end
			sess_status_kind = merge_status(sess_status_kind, tab_status_kind)

			local tab_title = if t.name and t.name ~= "" and t.name ~= SIDEBAR_TITLE
				then t.name
				elseif primary_user_title and primary_user_title ~= "" then primary_user_title
				elseif t.title and t.title ~= "" and t.title ~= SIDEBAR_TITLE then t.title
				elseif t.program and t.program ~= "" then t.program
				else ("Tab " .. tostring(idx))
			local tab_stripped = strip_leading_title_icon(tab_title)
			if tab_stripped ~= "" then
				tab_title = tab_stripped
			end

			-- The tab shows its agent pane's icon: a busy one, else the focused one, else any.
			local tab_agent_icon = tab_agent_icon_of(pane_entries) or agent_icon_from_text(t.program)
			local tab_icon = tab_agent_icon
			if not tab_icon then
				for _, p in ipairs(pane_entries) do
					if p.focused then
						tab_icon = p.icon
						break
					end
				end
				tab_icon = tab_icon or (pane_entries[1] and pane_entries[1].icon) or "terminal"
			end

			-- Skip pure-sidebar transient tabs if there are other tabs in the session
			local only_sidebar = (#pane_entries == 0 and #stabs > 1)
			if not only_sidebar then
				table.insert(tab_entries, {
					id = t.id,
					session_id = s.id,
					pos = #tab_entries + 1,
					title = short_text(tab_title, 64),
					busy = tab_busy,
					status = tab_status_kind,
					current = is_cur_sess and (t.id == active_tab_id),
					icon = tab_icon,
					has_agent = (tab_agent_icon ~= nil),
					panes = pane_entries,
				})
			end
		end

		local grp: GroupId = persisted.groups[skey] or "todo"
		if not GROUP_BY_ID[grp] then
			grp = "todo"
		end
		if sess_busy and grp == "todo" and not persisted.manual_groups[skey] then
			grp = "doing"
			persisted.groups[skey] = "doing"
			state_dirty = true
		end
		persisted.groups[skey] = grp

		local gcounts = group_counts[grp]
		for _, t in ipairs(tab_entries) do
			for _, p in ipairs(t.panes) do
				if p.is_agent then
					gcounts.total += 1
					if p.busy then
						gcounts.running += 1
					else
						gcounts.idle += 1
					end
				end
			end
		end

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
			pos = #by_group[grp] + 1,
			current = is_cur_sess,
			busy = sess_busy,
			status = sess_status_kind,
			tabs = tab_entries,
			pane_count = sess_pane_count,
		}
		table.insert(sessions, entry)
		table.insert(by_group[grp], entry)
		by_skey[skey] = entry
	end

	for _, g in ipairs(GROUPS) do
		local g_list = by_group[g.id]
		local orig_idx: { [string]: number } = {}
		for idx, item in ipairs(g_list) do
			orig_idx[item.skey] = idx
		end
		table.sort(g_list, function(a, b)
			local oa = persisted.session_order[a.skey]
			local ob = persisted.session_order[b.skey]
			if oa ~= nil and ob ~= nil and oa ~= ob then
				return oa < ob
			elseif oa ~= nil and ob == nil then
				return true
			elseif oa == nil and ob ~= nil then
				return false
			end
			return (orig_idx[a.skey] or 0) < (orig_idx[b.skey] or 0)
		end)
		for idx, item in ipairs(g_list) do
			item.pos = idx
			if persisted.session_order[item.skey] ~= idx then
				persisted.session_order[item.skey] = idx
				state_dirty = true
			end
		end
	end

	if state_dirty then
		save_state()
	end

	return {
		sessions = sessions,
		by_group = by_group,
		by_skey = by_skey,
		group_counts = group_counts,
		active_session_id = active_session_id,
		active_tab_id = active_tab_id,
		focused_pane = focused,
		owned = owned,
	}
end

-- ---------------------------------------------------------------------------
-- View Fingerprint & Node Builder
-- ---------------------------------------------------------------------------
local SECTION_KEYS = { "toolbar" }
for _, g in ipairs(GROUPS) do
	table.insert(SECTION_KEYS, "group_" .. g.id)
end

-- A stage is drawn unless its pill is off or "hide empty" hides it while it holds no session.
local function stage_hidden(g: GroupSpec, count: number): boolean
	return persisted.stage_vis[g.id] == false or (persisted.hide_empty and count == 0)
end

-- Returns the whole-view fingerprint plus one fingerprint per direct child of `sidebar2_root`,
-- so a render can patch only the sections whose content actually changed.
local function build_fingerprint(data: CollectedData): (string, { [string]: string })
	local parts: { string } = {
		tostring(persisted.visible),
		persisted.side,
		tostring(picked_skey or ""),
		tostring(hover_group or ""),
		tostring(hover_sess_pos or ""),
		tostring(picked_tab_id or ""),
		tostring(hover_tab_pos or ""),
		tostring(data.active_session_id or 0),
		tostring(data.active_tab_id or 0),
		tostring(data.focused_pane or 0),
		tostring(persisted.badge_vis.total),
		tostring(persisted.badge_vis.running),
		tostring(persisted.badge_vis.idle),
		tostring(badge_cfg_open),
		tostring(stage_cfg_open),
	}
	local sec_fp: { [string]: string } = {
		toolbar = table.concat({ persisted.side, tostring(#data.sessions) }, "|"),
	}
	for _, g in ipairs(GROUPS) do
		if stage_hidden(g, #(data.by_group[g.id] or {})) then
			continue
		end
		local gfold = persisted.fold_groups[g.id] == true
		local counts = data.group_counts[g.id]
		local g_parts: { string } = {
			g.id,
			tostring(gfold),
			tostring(counts.total),
			tostring(counts.running),
			tostring(counts.idle),
			tostring(persisted.badge_vis.total),
			tostring(persisted.badge_vis.running),
			tostring(persisted.badge_vis.idle),
			tostring(persisted.badge_vis.hide_zero),
		}
		-- Dragging repaints from the drop handlers themselves; keeping the state here means a
		-- background tick never leaves a stale pick marker behind.
		if picked_skey ~= nil then
			table.insert(
				g_parts,
				"pick:" .. tostring(hover_group or "") .. ":" .. tostring(hover_sess_pos or "")
			)
		end
		for _, s in ipairs(data.by_group[g.id]) do
			local sfold = persisted.fold_sessions[s.skey] == true
			table.insert(
				g_parts,
				table.concat({
					s.skey,
					s.group,
					tostring(s.pos),
					tostring(s.current),
					tostring(s.busy),
					s.status,
					tostring(#s.tabs),
					tostring(s.pane_count),
				}, ",")
			)
			if picked_tab_id ~= nil and s.id == picked_tab_sess then
				table.insert(g_parts, "tabpick:" .. tostring(picked_tab_id) .. ":" .. tostring(hover_tab_pos or ""))
			end
			if not gfold and not sfold then
				for _, t in ipairs(s.tabs) do
					local tkey = tostring(t.id)
					local tfold = persisted.fold_tabs[tkey] == true
					local tmarked = persisted.marked_tabs[tkey] == true
					table.insert(
						g_parts,
						table.concat({
							tkey,
							tostring(t.pos),
							t.title,
							tostring(t.current),
							tostring(t.busy),
							t.status,
							tostring(#t.panes),
							t.icon,
							tostring(tmarked),
						}, ";")
					)
					if not tfold then
						for _, p in ipairs(t.panes) do
							table.insert(
								g_parts,
								table.concat({
									tostring(p.id),
									p.kind,
									p.title,
									tostring(p.sub or ""),
									tostring(p.busy),
									tostring(p.err),
									p.status,
									tostring(p.focused),
									p.icon,
								}, "/")
							)
						end
					end
				end
			end
		end
		local sec = table.concat(g_parts, "|")
		sec_fp["group_" .. g.id] = sec
		table.insert(parts, sec)
	end
	return table.concat(parts, "|"), sec_fp
end

type DomLevel1 = {
	skey: string,
	sess_id: number,
	group: string,
	name: string,
	pos: number,
	group_count: number,
}

type DomLevel2 = {
	tab_id: number,
	sess_id: number,
	pos: number,
	title: string,
	tab_count: number,
	has_sub: boolean,
}
local function status_icon_node(key: string, st: ItemStatus): Node?
	if st == "working" then
		return ui.node("badge", {
			key = key,
			role = "sidebar2.status.working",
			text = "✦",
			tone = "warning",
		})
	elseif st == "unread" then
		return ui.node("badge", {
			key = key,
			role = "sidebar2.status.unread",
			text = "✦",
			tone = "success",
		})
	elseif st == "read" then
		return ui.node("badge", {
			key = key,
			role = "sidebar2.status.read",
			text = "✦",
			tone = "neutral",
		})
	end
	return nil
end

local function build_view(data: CollectedData): (Node, Node, { [string]: Node })
	local root_children: { Node } = {}
	local picked_sess_entry = if picked_skey then data.by_skey[picked_skey] else nil
	local dom_level1: { DomLevel1 } = {}
	local dom_level2: { DomLevel2 } = {}
	local dom_fp_parts: { string } = { persisted.side, tostring(badge_cfg_open) }
	-- 1. Top Toolbar
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
			ui.button(if persisted.side == "left" then "R" else "L", {
				key = "btn_side",
				icon = if persisted.side == "left" then "dock-right" else "dock-left",
				size = "sm",
				variant = "quiet",
				title = "Switch sidebar Left / Right",
				actions = { click = "flip_side" },
			}),
			ui.button("", {
				key = "btn_fold_all",
				icon = "shrink",
				size = "sm",
				variant = "quiet",
				title = "Fold / Expand all sessions",
				actions = { click = "fold_all" },
			}),
			ui.button("", {
				key = "btn_refresh",
				icon = "repeat",
				size = "sm",
				variant = "quiet",
				title = "Refresh Kanban sidebar",
				actions = { click = "refresh" },
			}),
			ui.button("", {
				key = "btn_hide",
				icon = "x",
				size = "sm",
				variant = "quiet",
				title = "Ẩn sidebar (Ctrl+Alt+B)",
				actions = { click = "hide_sidebar" },
			}),
		}),
	})
	table.insert(root_children, toolbar)


	-- 3. Kanban Groups: one column per stage
	for _, g in ipairs(GROUPS) do
		local g_entries = data.by_group[g.id] or {}
		if stage_hidden(g, #g_entries) then
			continue
		end
		local g_folded = persisted.fold_groups[g.id] == true
		local g_chev = if g_folded then "▸" else "▾"
		local group_children: { Node } = {}
		table.insert(dom_fp_parts, "G:" .. g.id .. ":" .. tostring(g_folded) .. ":" .. tostring(#g_entries))

		local is_group_drop_target = (picked_skey ~= nil and (hover_group == g.id or hover_group == nil))
		local head_click = if picked_skey then ("drop_group=" .. g.id) else ("fold_group=" .. g.id)
		local counts = data.group_counts[g.id]
		local hide_zero = persisted.badge_vis.hide_zero == true
		local head_right_children: { Node } = {}
		if is_group_drop_target then
			table.insert(head_right_children, ui.badge("↓ Drop here", g.tone))
		else
			if persisted.badge_vis.total ~= false and not (hide_zero and counts.total == 0) then
				table.insert(
					head_right_children,
					ui.node("badge", {
						key = "cnt_tot_" .. g.id,
						role = "sidebar2.count.total",
						text = tostring(counts.total),
						tone = "info",
						title = "Tổng số Agent: " .. tostring(counts.total),
					})
				)
			end
			if persisted.badge_vis.running ~= false and not (hide_zero and counts.running == 0) then
				table.insert(
					head_right_children,
					ui.node("badge", {
						key = "cnt_run_" .. g.id,
						role = "sidebar2.count.running",
						text = tostring(counts.running),
						tone = "warning",
						title = "Agent đang chạy: " .. tostring(counts.running),
					})
				)
			end
			if persisted.badge_vis.idle ~= false and not (hide_zero and counts.idle == 0) then
				table.insert(
					head_right_children,
					ui.node("badge", {
						key = "cnt_idl_" .. g.id,
						role = "sidebar2.count.idle",
						text = tostring(counts.idle),
						tone = "success",
						title = "Agent đang idle: " .. tostring(counts.idle),
					})
				)
			end
		end
		table.insert(head_right_children, ui.text({ ui.span(g_chev, "muted") }))
		local ghead_key = "ghead_" .. g.id
		local group_head = ui.node("row", {
			key = ghead_key,
			role = "sidebar2.group_head",
			justify = "between",
			align = "center",
			actions = {
				click = head_click,
				menu = {
					{ header = g.label },
					{ id = "new_session_in=" .. g.id, label = "New Session", icon = "plus" },
					"-",
					{
						id = "fold_group=" .. g.id,
						label = if g_folded then "Expand Group" else "Collapse Group",
						icon = if g_folded then "expand" else "shrink",
					},
				},
			},
		}, {
			ui.text({
				ui.span(g.label, "strong " .. g.tone),
			}),
			ui.node("row", {
				key = "ghead_right_" .. g.id,
				role = "sidebar2.group_counts",
				align = "center",
			}, head_right_children),
		})
		table.insert(group_children, group_head)

		if not g_folded then
			if #g_entries == 0 then
				local is_empty_drop = (picked_skey ~= nil and hover_group == g.id)
				table.insert(
					group_children,
					ui.node("row", {
						key = "empty_" .. g.id,
						role = "sidebar2.empty",
						mark = if is_empty_drop then "drop_target" else nil,
						actions = if picked_skey ~= nil
							then { click = "drop_sess=" .. g.id .. ":1" }
							else nil,
					}, {
						ui.text({ ui.span("No sessions in " .. g.label, "muted") }),
					})
				)
			else
				for _, sess in ipairs(g_entries) do
					local s_folded = persisted.fold_sessions[sess.skey] == true
					local s_chev = if s_folded then "▸" else "▾"
					local is_picked = (picked_skey == sess.skey)
					local can_reorder_sess = #g_entries >= 2
					local is_same_group_drag = (
						picked_sess_entry ~= nil and picked_sess_entry.group == g.id
					)
					-- Moving into another group can append past the last row (`N + 1`), which no row
					-- of its own represents; the last row carries that mark instead.
					local is_append_after_last = (
						not is_same_group_drag
						and picked_skey ~= nil
						and hover_group == g.id
						and hover_sess_pos ~= nil
						and hover_sess_pos > #g_entries
						and sess.pos == #g_entries
					)
					local is_sess_drop_target = (
						picked_skey ~= nil
						and picked_skey ~= sess.skey
						and (hover_group == nil or hover_group == g.id)
						and (hover_sess_pos == nil or hover_sess_pos == sess.pos or is_append_after_last)
					)
					local effective_drop_pos = if is_append_after_last then (#g_entries + 1) else sess.pos
					local drop_sess_act = "drop_sess=" .. g.id .. ":" .. tostring(effective_drop_pos)
					local sess_drop_mark = if not is_sess_drop_target or hover_group ~= g.id or hover_sess_pos == nil
						then nil
						elseif is_append_after_last
							or (is_same_group_drag and picked_sess_entry and sess.pos > picked_sess_entry.pos)
							then "drop_after"
						else "drop_before"
					local l1_role = if sess.current then "sidebar2.level1.current" else "sidebar2.level1"
					local host_badge_tone = if sess.host_kind == "remote" then "info" else "neutral"
					local sess_st_node = status_icon_node("st_s_" .. sess.skey, sess.status)

					local l1_menu: { any } = {
						{ header = sess.host_name .. " · " .. sess.name },
						{ id = "new_tab_in=" .. tostring(sess.id), label = "New Tab", icon = "plus" },
						{ id = "new_omp_in=" .. tostring(sess.id), label = "New Tab omp", icon = "open" },
						"-",
						{ id = "focus_sess=" .. tostring(sess.id), label = "Focus Session", icon = "open" },
						{ id = "rename_sess=" .. tostring(sess.id), label = "Rename Session…", icon = "pen" },
						"-",
						{ header = "Kanban Stage" },
					}
					for _, gspec in ipairs(GROUPS) do
						table.insert(l1_menu, {
							id = "move_group=" .. gspec.id .. ":" .. sess.skey,
							label = "Move to " .. gspec.label,
							icon = gspec.icon,
							radio = "stage",
							checked = (sess.group == gspec.id),
						})
					end
					table.insert(l1_menu, "-")
					table.insert(l1_menu, {
						id = "pick=" .. sess.skey,
						label = if is_picked then "Cancel Pick Session" else "Pick Session",
						icon = "grip",
					})
					if can_reorder_sess then
						if sess.pos > 1 then
							table.insert(l1_menu, {
								id = "sess_move=" .. g.id .. ":" .. tostring(sess.pos - 1) .. ":" .. sess.skey,
								label = "Move Session Up",
								icon = "arrow-up",
							})
						end
						if sess.pos < #g_entries then
							table.insert(l1_menu, {
								id = "sess_move=" .. g.id .. ":" .. tostring(sess.pos + 1) .. ":" .. sess.skey,
								label = "Move Session Down",
								icon = "arrow-down",
							})
						end
					end
					table.insert(dom_level1, {
						skey = sess.skey,
						sess_id = sess.id,
						group = g.id,
						name = sess.name,
						pos = sess.pos,
						group_count = #g_entries,
					})
					table.insert(dom_fp_parts, "L1:" .. sess.skey .. ":" .. g.id .. ":" .. tostring(sess.pos) .. ":" .. tostring(s_folded))

					local l1_right_badge = if is_sess_drop_target
						then ui.node("badge", {
							key = "drop_s_" .. sess.skey,
							text = "↕ #" .. tostring(effective_drop_pos),
							tone = "info",
							actions = { click = drop_sess_act },
						})
						else ui.node("badge", {
							key = "fold_s_" .. sess.skey,
							text = s_chev,
							tone = "neutral",
							actions = { click = "fold_sess=" .. sess.skey, menu = l1_menu },
						})

					-- Level 1 Row: Host + Session name (drag anywhere on row or click ⠿)
					local l1_right_items: { Node } = {}
					if sess_st_node then
						table.insert(l1_right_items, sess_st_node)
					end
					table.insert(l1_right_items, l1_right_badge)

					local l1_row = ui.node("row", {
						key = "l1_" .. sess.skey,
						role = l1_role,
						mark = if is_picked then "pick" else sess_drop_mark,
						justify = "between",
						align = "center",
					}, {
						ui.node("badge", {
							key = "pick_s_" .. sess.skey,
							role = "sidebar2.grip1",
							text = if is_picked then "🎯" elseif is_sess_drop_target then "↕" else "⠿",
							tone = if is_picked
								then "warning"
								elseif is_sess_drop_target then "info"
								else "neutral",
							actions = {
								click = if is_sess_drop_target then drop_sess_act else ("pick=" .. sess.skey),
								menu = l1_menu,
							},
						}),
						ui.node("row", {
							key = "title_s_" .. sess.skey,
							role = "sidebar2.l1_title",
							align = "center",
							title = sess.host_name
								.. " · "
								.. sess.name
								.. " ("
								.. tostring(#sess.tabs)
								.. " tabs)",
							actions = {
								click = if is_sess_drop_target then drop_sess_act else ("focus_sess=" .. tostring(sess.id)),
								menu = l1_menu,
							},
						}, {
							ui.badge(sess.host_name, host_badge_tone),
							ui.text({
								ui.span(
									short_text(sess.name, 20),
									if sess.current then "strong" else nil
								),
								ui.span(" " .. tostring(#sess.tabs) .. "t", "muted"),
							}),
						}),
						ui.node("row", {
							key = "right_s_" .. sess.skey,
							role = "sidebar2.right_icons",
							align = "center",
						}, l1_right_items),
					})
					table.insert(group_children, l1_row)

					-- Level 2: Tabs inside Session (non-nested interactive children)
					if not s_folded then
						local can_reorder_tabs = #sess.tabs >= 2
						for _, tab in ipairs(sess.tabs) do
							local tkey = tostring(tab.id)
							local has_sub = #tab.panes >= 2
							local t_folded = persisted.fold_tabs[tkey] == true
							local t_marked = persisted.marked_tabs[tkey] == true
							local t_chev = if t_folded then "▸" else "▾"
							local is_tab_picked = (picked_tab_id == tab.id)
							local is_tab_drop_target = (
								picked_tab_id ~= nil
								and picked_tab_sess == sess.id
								and picked_tab_id ~= tab.id
								and (hover_tab_pos == nil or hover_tab_pos == tab.pos)
							)
							local picked_tab_pos: number? = nil
							if picked_tab_sess == sess.id then
								for _, pt in ipairs(sess.tabs) do
									if pt.id == picked_tab_id then
										picked_tab_pos = pt.pos
										break
									end
								end
							end
							local tab_drop_mark = if not is_tab_drop_target or hover_tab_pos == nil
								then nil
								elseif picked_tab_pos and tab.pos > picked_tab_pos
									then "drop_after"
								else "drop_before"
							local l2_role = if tab.current then "sidebar2.level2.current" else "sidebar2.level2"
							local tab_st_node = status_icon_node("st_t_" .. tkey, tab.status)
							local focus_tab_act = "focus_tab=" .. tostring(sess.id) .. ":" .. tkey
							local pick_tab_act = "pick_tab=" .. tostring(sess.id) .. ":" .. tkey
							local drop_tab_act = "drop_tab=" .. tostring(tab.pos)
							local primary_tab_act = if is_tab_drop_target then drop_tab_act else focus_tab_act

							table.insert(dom_level2, {
								tab_id = tab.id,
								sess_id = sess.id,
								pos = tab.pos,
								title = tab.title,
								tab_count = #sess.tabs,
								has_sub = has_sub,
							})
							table.insert(
								dom_fp_parts,
								"L2:"
									.. tkey
									.. ":"
									.. tostring(tab.pos)
									.. ":"
									.. tostring(t_folded)
									.. ":"
									.. tostring(if has_sub and not t_folded then #tab.panes else 0)
							)

							local l2_menu: { any } = {
								{ header = "#" .. tostring(tab.pos) .. " " .. tab.title },
								{ id = "new_tab_in=" .. tostring(sess.id) .. ":" .. tkey, label = "New Tab", icon = "plus" },
								{ id = "new_omp_in=" .. tostring(sess.id) .. ":" .. tkey, label = "New Tab omp", icon = "open" },
								{
									id = "close_tab=" .. tostring(sess.id) .. ":" .. tkey,
									label = "Close Tab",
									icon = "trash",
									danger = true,
								},
								"-",
								{
									id = "mark_tab=" .. tkey,
									label = if t_marked then "Bỏ đánh dấu" else "Đánh dấu cần đọc",
									icon = if t_marked then "check" else "eye",
								},
								"-",
								{
									id = "focus_tab=" .. tostring(sess.id) .. ":" .. tkey,
									label = "Focus Tab",
									icon = "open",
								},
								{ id = "rename_tab=" .. tkey, label = "Rename Tab…", icon = "pen" },
							}
							if can_reorder_tabs then
								table.insert(l2_menu, "-")
								table.insert(l2_menu, {
									id = "pick_tab=" .. tostring(sess.id) .. ":" .. tkey,
									label = if is_tab_picked then "Cancel Pick Tab" else "Pick Tab",
									icon = "grip",
								})
								if tab.pos > 1 then
									table.insert(l2_menu, {
										id = "tab_move=" .. tkey .. ":" .. tostring(tab.pos - 1),
										label = "Move Tab Up",
										icon = "arrow-up",
									})
								end
								if tab.pos < #sess.tabs then
									table.insert(l2_menu, {
										id = "tab_move=" .. tkey .. ":" .. tostring(tab.pos + 1),
										label = "Move Tab Down",
										icon = "arrow-down",
									})
								end
							end

							local l2_children: { Node } = {}
							if can_reorder_tabs then
								table.insert(
									l2_children,
									ui.node("badge", {
										key = "pick_t_" .. tkey,
										role = "sidebar2.grip2",
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
									gap = "xs",
									title = "#"
										.. tostring(tab.pos)
										.. " "
										.. tab.title
										.. " ("
										.. tostring(#tab.panes)
										.. " panes)",
									actions = { click = primary_tab_act, menu = l2_menu },
								}, {
									ui.node("icon", {
										name = tab.icon,
										tone = if tab.current
											then "accent"
											elseif tab.has_agent then "info"
											else "neutral",
									}),
									ui.text({
										ui.span("#" .. tostring(tab.pos) .. " ", "muted"),
										ui.span(
											tab.title,
											if tab.current then "strong" else nil
										),
										if has_sub
											then ui.span(" " .. tostring(#tab.panes) .. "p", "muted")
											else ui.span("", nil),
									}),
								})
							)

							local l2_right_items: { Node } = {}
							if t_marked then
								table.insert(
									l2_right_items,
									ui.node("badge", {
										key = "mark_t_" .. tkey,
										role = "sidebar2.tab_mark",
										text = "⚑",
										tone = "error",
										title = "Tab cần đọc (Click hoặc chuột phải để bỏ đánh dấu)",
										actions = { click = "mark_tab=" .. tkey, menu = l2_menu },
									})
								)
							end
							if tab_st_node then
								table.insert(l2_right_items, tab_st_node)
							end
							if is_tab_drop_target then
								table.insert(
									l2_right_items,
									ui.node("badge", {
										key = "drop_t_" .. tkey,
										text = "↕ #" .. tostring(tab.pos),
										tone = "info",
										actions = { click = drop_tab_act },
									})
								)
							elseif has_sub then
								table.insert(
									l2_right_items,
									ui.node("badge", {
										key = "fold_t_" .. tkey,
										text = t_chev,
										tone = "neutral",
										actions = { click = "fold_tab=" .. tkey, menu = l2_menu },
									})
								)
							end
							if #l2_right_items > 0 then
								table.insert(
									l2_children,
									ui.node("row", {
										key = "right_t_" .. tkey,
										role = "sidebar2.right_icons",
										align = "center",
									}, l2_right_items)
								)
							end

							local l2_row = ui.node("row", {
								key = "l2_" .. tkey,
								role = l2_role,
								mark = if is_tab_picked then "pick" else tab_drop_mark,
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
									local status_badge = status_icon_node("st_p_" .. pkey, pane.status)
									local label_spans: { Span | string } = {
										ui.span(pane.title, if pane.focused then "strong" else nil),
									}
									if pane.sub and pane.sub ~= "" then
										table.insert(label_spans, ui.span(" · " .. pane.sub, "muted"))
									end

									local l3_children: { Node } = {
										ui.node("row", {
											key = "title_p_" .. pkey,
											gap = "xs",
											align = "center",
											grow = 1,
										}, {
											ui.node("icon", {
												name = pane.icon,
												tone = if pane.err
													then "error"
													elseif pane.focused then "accent"
													else "neutral",
											}),
											ui.text(label_spans),
										}),
									}
									if status_badge then
										table.insert(l3_children, status_badge)
									end

									local l3_row = ui.node("row", {
										key = "l3_" .. pkey,
										role = l3_role,
										justify = "between",
										align = "center",
										title = if pane.sub and pane.sub ~= ""
											then (pane.title .. " — " .. pane.sub)
											else pane.title,
										actions = {
											click = focus_pane_act,
											menu = {
												{ header = pane.title },
												{ id = "focus_pane=" .. tostring(sess.id) .. ":" .. tkey .. ":" .. pkey, label = "Focus Pane", icon = "open" },
												"-",
												{ id = "split_right=" .. pkey, label = "Split Right", icon = "split" },
												{ id = "split_down=" .. pkey, label = "Split Down", icon = "split-down" },
												"-",
												{ id = "close_pane=" .. pkey, label = "Close Pane", icon = "trash", danger = true },
											},
										},
									}, l3_children)
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
				role = "sidebar2.group." .. g.id,
			}, group_children)
		)
	end
	if not picked_skey and not picked_tab_id then
		local map_fp = table.concat(dom_fp_parts, "|")
		if map_fp ~= last_dom_map_fp then
			last_dom_map_fp = map_fp
			dom_map_seq += 1
			pcall(tern.kv.set, "dom_map", {
				seq = dom_map_seq,
				side = persisted.side,
				active_pane = data.focused_pane,
				level1 = tern.json.array(dom_level1),
				level2 = tern.json.array(dom_level2),
			})
		end
	end

	local sections: { [string]: Node } = {}
	for _, child in ipairs(root_children) do
		if child.p and child.p.key then
			sections[child.p.key] = child
		end
	end

	local view = ui.node("col", {
		key = "sidebar2_root",
		role = "sidebar2.root",
	}, root_children)

	local badge_cfg_menu: { any } = {
		{ header = "Hiển thị số lượng Agent" },
		{
			id = "toggle_badge=total",
			label = "Tổng số Agent (Total)",
			checked = (persisted.badge_vis.total ~= false),
		},
		{
			id = "toggle_badge=running",
			label = "Agent đang chạy (Running)",
			checked = (persisted.badge_vis.running ~= false),
		},
		{
			id = "toggle_badge=idle",
			label = "Agent đang idle (Idle)",
			checked = (persisted.badge_vis.idle ~= false),
		},
		"-",
		{
			id = "toggle_badge=hide_zero",
			label = "Ẩn badge khi số lượng = 0",
			checked = persisted.badge_vis.hide_zero,
		},
	}

	local dock_rows: { Node } = {}
	if badge_cfg_open then
		table.insert(
			dock_rows,
			ui.node("row", {
				key = "dock_badge_bar",
				role = "sidebar2.dock_filter",
				justify = "between",
				align = "center",
			}, {
				ui.node("badge", {
					key = "flt_total",
					role = if persisted.badge_vis.total then "sidebar2.count.total" else "sidebar2.count.off",
					text = (if persisted.badge_vis.total then "✓ " else "○ ") .. "Tổng",
					tone = if persisted.badge_vis.total then "info" else "neutral",
					title = "Ẩn/hiện Tổng số Agent",
					actions = { click = "toggle_badge=total" },
				}),
				ui.node("badge", {
					key = "flt_running",
					role = if persisted.badge_vis.running then "sidebar2.count.running" else "sidebar2.count.off",
					text = (if persisted.badge_vis.running then "✓ " else "○ ") .. "Chạy",
					tone = if persisted.badge_vis.running then "warning" else "neutral",
					title = "Ẩn/hiện Agent đang chạy",
					actions = { click = "toggle_badge=running" },
				}),
				ui.node("badge", {
					key = "flt_idle",
					role = if persisted.badge_vis.idle then "sidebar2.count.idle" else "sidebar2.count.off",
					text = (if persisted.badge_vis.idle then "✓ " else "○ ") .. "Idle",
					tone = if persisted.badge_vis.idle then "success" else "neutral",
					title = "Ẩn/hiện Agent đang idle",
					actions = { click = "toggle_badge=idle" },
				}),
				ui.node("badge", {
					key = "flt_zero",
					role = if persisted.badge_vis.hide_zero then "sidebar2.count.zero" else "sidebar2.count.off",
					text = (if persisted.badge_vis.hide_zero then "✓ " else "○ ") .. "Ẩn 0",
					tone = if persisted.badge_vis.hide_zero then "info" else "neutral",
					title = "Ẩn/hiện badge có số lượng = 0",
					actions = { click = "toggle_badge=hide_zero" },
				}),
			})
		)
	end
	if stage_cfg_open then
		local stage_row: { Node } = {}
		local row_n = 0
		local function flush_stage_row()
			if #stage_row > 0 then
				row_n += 1
				table.insert(
					dock_rows,
					ui.node("row", {
						key = "dock_stage_bar_" .. tostring(row_n),
						role = "sidebar2.dock_filter",
						justify = "between",
						align = "center",
					}, stage_row)
				)
				stage_row = {}
			end
		end
		for _, g in ipairs(GROUPS) do
			local on = persisted.stage_vis[g.id] ~= false
			table.insert(stage_row, ui.node("badge", {
				key = "stage_vis_" .. g.id,
				role = if on then "sidebar2.stage.on" else "sidebar2.stage.off",
				text = (if on then "✓ " else "○ ") .. g.label,
				tone = if on then g.tone else "neutral",
				title = "Ẩn/hiện trạng thái " .. g.label,
				actions = { click = "toggle_stage=" .. g.id },
			}))
			if #stage_row == 2 then
				flush_stage_row()
			end
		end
		local he_on = persisted.hide_empty
		table.insert(stage_row, ui.node("badge", {
			key = "stage_hide_empty",
			role = if he_on then "sidebar2.stage.on" else "sidebar2.stage.off",
			text = (if he_on then "✓ " else "○ ") .. "Ẩn trống",
			tone = if he_on then "info" else "neutral",
			title = "Ẩn trạng thái không có session",
			actions = { click = "toggle_hide_empty" },
		}))
		flush_stage_row()
	end
	table.insert(
		dock_rows,
		ui.node("row", {
			key = "dock_main_row",
			justify = "between",
			align = "center",
		}, {
			ui.button("Session", {
				key = "dock_new_sess",
				icon = "plus",
				size = "sm",
				variant = "default",
				title = "Create new session",
				actions = { click = "new_session" },
			}),
			ui.row({
				ui.button("Move…", {
					key = "dock_move_sess",
					icon = "swap",
					size = "sm",
					variant = "quiet",
					title = "Move session to another stage",
					actions = { click = "move_modal" },
				}),
				ui.button("", {
					key = "dock_stage_cfg",
					icon = "kanban",
					size = "sm",
					variant = if stage_cfg_open then "default" else "quiet",
					title = "Tùy chỉnh hiển thị trạng thái",
					actions = { click = "toggle_stage_cfg" },
				}),
				ui.button("", {
					key = "dock_badge_cfg",
					icon = "sliders",
					size = "sm",
					variant = if badge_cfg_open then "default" else "quiet",
					title = "Tùy chỉnh hiển thị tổng số Agent (Click hoặc Chuột phải)",
					actions = {
						click = "toggle_badge_cfg",
						menu = badge_cfg_menu,
					},
				}),
			}),
		})
	)
	local dock = ui.node("col", {
		key = "sidebar2_dock",
		role = "sidebar2.dock",
	}, dock_rows)

	return view, dock, sections
end

-- ---------------------------------------------------------------------------
-- Fixed Sidebar Layout Engine (Per-Host Canvas + Ratio Sync + Refocus)
-- ---------------------------------------------------------------------------
local function close_all_sidebars(cx: WindowCx)
	active_sidebar_pane = nil
	local owned = owned_canvases(cx)
	for spane, _ in pairs(owned) do
		painted_fp[spane] = nil
		painted_sec_fp[spane] = nil
		persisted.owned_panes[tostring(spane)] = nil
		closing_internally[spane] = true
		pcall(function()
			cx.layout:close(spane)
		end)
	end
	close_stale_canvases(cx)
	save_state()
	table.clear(synced_tab_ratio)
end

local place_sidebar_at_edge: (WindowCx, number, number, "left" | "right", number) -> boolean

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
	table.sort(sess_tabs, function(a, b)
		if a.position ~= b.position then
			return a.position < b.position
		end
		return a.id < b.id
	end)
	if #sess_tabs <= 1 then
		return
	end

	-- Sidebar-only tabs: move their canvas into the nearest sibling tab that still has a user pane
	local orphans: { { tab_id: number, spanes: { number } } } = {}
	for _, t in ipairs(sess_tabs) do
		local has_user = false
		local spanes: { number } = {}
		for _, pid in ipairs(tab_all_panes(cx, t.id)) do
			if owned[pid] then
				table.insert(spanes, pid)
			else
				has_user = true
			end
		end
		if not has_user and #spanes > 0 then
			table.insert(orphans, { tab_id = t.id, spanes = spanes })
		end
	end

	for _, item in ipairs(orphans) do
		local target_tab = find_best_sibling_tab(cx, active_session_id, item.tab_id, owned)
		local u = if target_tab then first_user_pane(cx, target_tab, owned) else nil
		synced_tab_ratio[item.tab_id] = nil
		for idx, spane in ipairs(item.spanes) do
			if u and target_tab and idx == 1 then
				synced_tab_ratio[target_tab] = nil
				place_sidebar_at_edge(cx, spane, target_tab, persisted.side, persisted.ratio)
			else
				closing_internally[spane] = true
				persisted.owned_panes[tostring(spane)] = nil
				painted_fp[spane] = nil
				opened_at_ms[spane] = nil
				pcall(function()
					cx.layout:close(spane)
				end)
			end
		end
		if u and target_tab then
			last_user_pane_by_tab[target_tab] = u
			pcall(function()
				cx.layout:focus(u)
			end)
		end
	end
end

local function find_host_sidebar(
	cx: WindowCx,
	host_id: number,
	active_tab_id: number?,
	owned: { [number]: boolean }
): number?
	local live = live_host_canvases(cx)
	-- A canvas spawned a moment ago has no runtime entry yet; counting it keeps every later sync
	-- from opening a second one (spawn/close churn made the sidebar flicker away). Only panes that
	-- still sit in a tab qualify: ids left over in kv.json are not canvases and painting them throws.
	for pid, _ in pairs(owned) do
		if cx.session:tab_of(pid) ~= nil then
			live[pid] = true
		end
	end
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
		closing_internally[ex] = true
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
	-- Share one column of this tab moves: resize works in whole cells, so half of one is the closest
	-- to the target any tab can land. The first step uses the estimate, the next measures the tab's
	-- own column count and lands every session on the same width.
	local per_cell: number? = nil
	for _ = 1, 5 do
		local ok, lay = pcall(function()
			return cx.session:layout(tab_id)
		end)
		if not ok or not lay then
			return
		end
		local at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
		if not at_edge or not cur_share then
			return
		end
		local diff = target_ratio - cur_share
		local unit = per_cell or (1 / persisted.cols_est)
		if math.abs(diff) <= unit * 0.5 then
			if per_cell then
				persisted.cols_est = 1 / per_cell
				save_state()
			end
			return
		end
		local cells = math.floor(diff / unit + (if diff >= 0 then 0.5 else -0.5))
		if cells == 0 then
			cells = if diff > 0 then 1 else -1
		end
		local moved_ok, moved = pcall(function()
			return cx.layout:resize(spane, resize_dir, cells)
		end)
		if not moved_ok or not moved then
			return
		end
		local ok2, lay2 = pcall(function()
			return cx.session:layout(tab_id)
		end)
		if not ok2 or not lay2 then
			return
		end
		local ok_edge2, new_share = is_sidebar_at_root_edge(lay2, spane, side)
		if not ok_edge2 or not new_share then
			return
		end
		local actual_delta = new_share - cur_share
		-- One-cell steps read back rounded, so only a multi-cell move measures the tab.
		if math.abs(cells) >= 3 and math.abs(actual_delta) > 1e-6 then
			local measured = math.abs(actual_delta / cells)
			if measured > 1 / 1200 and measured < 1 / 30 then
				per_cell = measured
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

local function is_pane_floating(lay: TabLayout?, spane: number): boolean
	if not lay or type(lay.floats) ~= "table" then
		return false
	end
	for _, f in ipairs(lay.floats) do
		if f.pane == spane then
			return true
		end
	end
	return false
end

place_sidebar_at_edge = function(
	cx: WindowCx,
	spane: number,
	tab_id: number,
	side: "left" | "right",
	target_ratio: number
): boolean
	local cur_tab = cx.session:tab_of(spane)
	local moved_tabs = false
	if cur_tab ~= tab_id then
		local ok_m, moved_ok = pcall(function()
			return cx.layout:move_to_tab(spane, tab_id, { focus = false })
		end)
		if not ok_m or moved_ok == false then
			return false
		end
		moved_tabs = true
		synced_tab_ratio[tab_id] = nil
	end

	local ok_l, lay = pcall(function()
		return cx.session:layout(tab_id)
	end)
	if not ok_l or not lay or lay.zoomed then
		return moved_tabs
	end

	if is_pane_floating(lay, spane) then
		pcall(function()
			cx.layout:dock(spane, nil, side, { focus = false })
		end)
		ok_l, lay = pcall(function()
			return cx.session:layout(tab_id)
		end)
		if not ok_l or not lay then
			return moved_tabs
		end
	end

	local at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
	if not at_edge then
		local target_leaf = edge_user_leaf(lay.root, side, spane)
		if target_leaf then
			pcall(function()
				cx.layout:move(spane, target_leaf, side, { focus = false })
			end)
			ok_l, lay = pcall(function()
				return cx.session:layout(tab_id)
			end)
			if lay then
				at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
			end
		end
		-- A root "down" split keeps the sidebar off the side edge: sink the other leaves under
		-- target_leaf so the vertical split ends up inside the user subtree instead of the root.
		if not at_edge and lay and lay.root and lay.root.split == "down" and target_leaf then
			local tree_panes: { number } = {}
			collect_tree_panes(lay.root, tree_panes)
			for _, pid in ipairs(tree_panes) do
				if pid ~= spane and pid ~= target_leaf then
					pcall(function()
						cx.layout:move(pid, target_leaf, "down", { focus = false })
					end)
				end
			end
			ok_l, lay = pcall(function()
				return cx.session:layout(tab_id)
			end)
			if lay then
				at_edge, cur_share = is_sidebar_at_root_edge(lay, spane, side)
			end
		end
		synced_tab_ratio[tab_id] = nil
		moved_tabs = true
	end

	if not at_edge or not cur_share then
		return moved_tabs
	end
	local prev = synced_tab_ratio[tab_id]
	if not moved_tabs and prev and math.abs(cur_share - prev) > 0.5 / persisted.cols_est then
		-- The divider was dragged by hand: that width is the one every session keeps, not drift to
		-- correct back to the default.
		persisted.ratio = clamp(cur_share, MIN_SIDEBAR_RATIO, MAX_SIDEBAR_RATIO)
		save_state()
		target_ratio = persisted.ratio
	end
	match_ratio(cx, spane, tab_id, side, target_ratio)
	-- Remember where a settled strip sits: a hand drag then accumulates against it until it passes
	-- the deadband, instead of each small step being re-seeded and never adopted.
	local ok_f, lay_f = pcall(function()
		return cx.session:layout(tab_id)
	end)
	if ok_f and lay_f then
		local ok_f2, share_f = is_sidebar_at_root_edge(lay_f, spane, side)
		if ok_f2 and share_f and math.abs(share_f - persisted.ratio) <= 0.5 / persisted.cols_est then
			synced_tab_ratio[tab_id] = share_f
		end
	end
	return moved_tabs
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
		render_pending = true
		return
	end
	busy_lock = true
	-- A hover frame only redraws the changed columns: moving the pane, refocusing the terminal
	-- and refreshing Chrome on every 30ms drag frame is what made dragging feel laggy.
	local drag_fast = last_drag_active and not force_paint and active_sidebar_pane ~= nil

	local ok, err = pcall(function()
		if not drag_fast then
			ensure_status_bar(cx)
		end

		if not persisted.visible then
			close_all_sidebars(cx)
			return
		end
		if not drag_fast then
			ensure_drag_helper()
		end
		-- A session with no tabs shows Tern's "No Terminals open" and has nothing to hold the
		-- sidebar: hand the window to a session that still has tabs.
		pcall(function()
			if drag_fast then
				return
			end
			local ok_t, tlist = pcall(function()
				return cx.session:tabs()
			end)
			local ok_cur, cur = pcall(function()
				return cx.sessions:current()
			end)
			if not ok_t or type(tlist) ~= "table" or not ok_cur or not cur then
				return
			end
			local cur_has_tab = false
			for _, t in ipairs(tlist) do
				if t.session == cur.id then
					cur_has_tab = true
					break
				end
			end
			if cur_has_tab then
				return
			end
			local same_host: { [number]: boolean } = {}
			local ok_ss, slist = pcall(function()
				return cx.sessions:list()
			end)
			if ok_ss and type(slist) == "table" then
				for _, si in ipairs(slist) do
					if si.host == cur.host then
						same_host[si.id] = true
					end
				end
			end
			local target: number? = nil
			local fallback: number? = nil
			for _, t in ipairs(tlist) do
				if t.session ~= cur.id then
					if same_host[t.session] then
						target = t.session
						break
					elseif not fallback then
						fallback = t.session
					end
				end
			end
			local pick = target or fallback
			if pick then
				cx.sessions:switch(pick)
			end
		end)
		local ok_cs, cur_sess = pcall(function()
			return cx.sessions:current()
		end)
		local active_sess_id = if ok_cs and cur_sess then cur_sess.id else nil
		local active_host_id = if ok_cs and cur_sess then cur_sess.host else 0

		local active_host_kind = "local"
		local active_host_tern = ""
		pcall(function()
			local h = cx.hosts:current()
			if h then
				active_host_kind = h.kind
				active_host_tern = if type(h.tern) == "string" then h.tern else ""
			end
		end)

		close_stale_canvases(cx, active_host_id)
		local owned = owned_canvases(cx)

		-- Clean up any orphan sidebar-only tab left behind after closing a tab's last terminal
		cleanup_orphan_sidebar_tabs(cx, owned, active_sess_id)
		owned = owned_canvases(cx)

		local data = collect_data(cx)
		local tab_id = data.active_tab_id
		if not tab_id then
			return
		end

		local user_pane = first_user_pane(cx, tab_id, data.owned)
		if not user_pane then
			-- A tab whose last user pane closed is closing: take the canvas with it instead of
			-- splitting a fresh terminal in, so a closed tab never comes back on its own.
			for pid, _ in pairs(data.owned) do
				if cx.session:tab_of(pid) == tab_id then
					closing_internally[pid] = true
					persisted.owned_panes[tostring(pid)] = nil
					painted_fp[pid] = nil
					opened_at_ms[pid] = nil
					pcall(function()
						cx.layout:close(pid)
					end)
				end
			end
			return
		end

		local spane = find_host_sidebar(cx, active_host_id, tab_id, data.owned)
		local fp, sec_fp = build_fingerprint(data)

		-- Building the tree is the expensive half of a sync, so it only happens when something
		-- is actually going to be drawn: a fresh canvas, a forced repaint, a changed view, a
		-- canvas still hydrating, or a leftover canvas that needs the same tree.
		local others: { number } = {}
		for other_pane, _ in pairs(live_host_canvases(cx)) do
			if other_pane ~= spane and (force_paint or painted_fp[other_pane] ~= fp) then
				table.insert(others, other_pane)
			end
		end
		local stale = spane == nil
			or force_paint
			or painted_fp[spane] ~= fp
			or #others > 0
			or needs_hydration(cx, spane)
		local view: Node? = nil
		local dock: Node? = nil
		local sections: { [string]: Node } = {}
		if stale then
			view, dock, sections = build_view(data)
		end

		if not spane then
			if not canvas_host_ready(active_host_id, active_host_tern) then
				return
			end
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
				refuse_canvas_on_host(active_host_id, active_host_tern)
				tern.log.warn("sidebar2: canvas unavailable on this host:", tostring(open_err))
				return
			end
			spane = opened_pane
			opened_at_ms[spane] = tern.now()
			persisted.owned_panes[tostring(spane)] = true
			save_state()
			painted_fp[spane] = fp
			painted_sec_fp[spane] = sec_fp
			place_sidebar_at_edge(cx, spane, tab_id, persisted.side, persisted.ratio)
			refocus_terminal(cx, tab_id, owned_canvases(cx))
			-- Schedule fast follow-up hydrations for remote SSH hosts where tern.canvas starts asynchronously
			for _, delay_ms in ipairs({ 150, 400, 900 }) do
				tern.timer(delay_ms, function(timer_cx: WindowCx?)
					if timer_cx and not busy_lock and persisted.visible then
						sync_and_render(timer_cx, true)
					end
				end)
			end
		else
			-- A pane left behind by a daemon without canvas support keeps its default title and
			-- draws nothing, yet the hub may accept updates for it forever. It was not opened by
			-- this VM, so close it: the next sync spawns a real canvas on this host.
			if opened_at_ms[spane] == nil and needs_hydration(cx, spane) then
				tern.log.warn("sidebar2: closing a sidebar pane that never drew", spane)
				drop_sidebar_pane(cx, spane)
				return
			end
			local moved_tabs = if drag_fast
				then false
				else place_sidebar_at_edge(cx, spane, tab_id, persisted.side, persisted.ratio)
			if not drag_fast and (moved_tabs or not last_drag_active) then
				refocus_terminal(cx, tab_id, data.owned)
			end
			if force_paint or painted_fp[spane] ~= fp or needs_hydration(cx, spane) then
				local painted = false
				local prev = painted_sec_fp[spane]
				-- Paint only the columns whose content changed; the rest stay mounted as they are.
				if not force_paint and not needs_hydration(cx, spane) and painted_fp[spane] ~= nil and prev ~= nil then
					local patch: { [string]: Node | false } = {}
					for _, k in ipairs(SECTION_KEYS) do
						if prev[k] ~= sec_fp[k] then
							-- A hidden stage has no section: false drops the column it left mounted.
							patch[k] = sections[k] or false
						end
					end
					if next(patch) == nil then
						-- Nothing visible changed (e.g. only hover bookkeeping): record it, draw nothing.
						painted = true
					else
						-- The canvas runtime may still be coming up right after a spawn: a failed
						-- paint just retries on the next sync and keeps the pane's spawn grace.
						painted = pcall(function()
							cx.canvas:set(spane, { set = patch })
						end)
					end
				end
				if not painted then
					local ok_full, full_err = pcall(function()
						cx.canvas:set(spane, {
							title = SIDEBAR_TITLE,
							about = SIDEBAR_ABOUT,
							view = view,
							dock = dock,
						})
					end)
					painted = ok_full
					if not ok_full then
						-- A canvas that just spawned may still be hydrating; a paint past that grace
						-- failing means the pane the runtime opened on this host is a plain pane,
						-- not a canvas: close it instead of repainting a blank strip every sync.
						local opened_t = opened_at_ms[spane]
						local hydrating = opened_t ~= nil and (tern.now() - opened_t) < 2500
						if hydrating then
							tern.log.debug("sidebar2: canvas still hydrating:", tostring(full_err))
						else
							-- Only a pane this VM opened proves the host cannot host canvases; one
							-- left behind by an older build just goes, so the next sync opens a
							-- fresh canvas instead of writing the host off.
							if opened_t ~= nil then
								refuse_canvas_on_host(active_host_id, active_host_tern)
							end
							if tern.now() - last_refusal_warn_s > 60_000 then
								last_refusal_warn_s = tern.now()
								tern.log.warn(
									"sidebar2: canvas refused on host",
									active_host_id,
									active_host_kind,
									":",
									tostring(full_err)
								)
							end
							drop_sidebar_pane(cx, spane)
							return
						end
					end
				end
				if painted then
					painted_fp[spane] = fp
					painted_sec_fp[spane] = sec_fp
				else
					painted_fp[spane] = nil
					painted_sec_fp[spane] = nil
				end
			end
		end
		active_sidebar_pane = spane
		for _, other_pane in ipairs(others) do
			pcall(function()
				cx.canvas:set(other_pane, {
					title = SIDEBAR_TITLE,
					about = SIDEBAR_ABOUT,
					view = view,
					dock = dock,
				})
				painted_fp[other_pane] = fp
				painted_sec_fp[other_pane] = sec_fp
			end)
		end
		last_active_session_id = data.active_session_id
		last_active_tab_id = tab_id
	end)

	busy_lock = false
	if not ok then
		tern.log.warn("sidebar2 sync error:", tostring(err))
	end
	if not drag_fast then
		pcall(tern.chrome.refresh)
	end
	if render_pending then
		render_pending = false
		sync_and_render(cx, force_paint)
	end
end

-- Close one tab without letting the sidebar ride along: it moves to the nearest sibling tab of
-- the same session first, then the tab's own panes close one by one.
local function close_tab_safely(cx: WindowCx, tid: number, hint_sess_id: number?)
	local target_sess: number? = nil
	local ok_t, tlist = pcall(function()
		return cx.session:tabs()
	end)
	if ok_t and type(tlist) == "table" then
		for _, t in ipairs(tlist) do
			if t.id == tid then
				target_sess = t.session
				break
			end
		end
	end
	if not target_sess then
		target_sess = hint_sess_id
	end

	local owned = owned_canvases(cx)
	local sibling_tid = find_best_sibling_tab(cx, target_sess, tid, owned)
	if sibling_tid then
		for spane, _ in pairs(owned) do
			if cx.session:tab_of(spane) == tid then
				synced_tab_ratio[tid] = nil
				synced_tab_ratio[sibling_tid] = nil
				place_sidebar_at_edge(cx, spane, sibling_tid, persisted.side, persisted.ratio)
			end
		end
		if target_sess == last_active_session_id and tid == last_active_tab_id then
			local u = first_user_pane(cx, sibling_tid, owned)
			if u then
				last_user_pane_by_tab[sibling_tid] = u
				pcall(function()
					cx.layout:focus(u)
				end)
			end
		end
	end

	local to_close: { [number]: boolean } = {}
	for _, pid in ipairs(tab_all_panes(cx, tid)) do
		if sibling_tid or not owned[pid] then
			to_close[pid] = true
		end
	end
	local ok_p, plist = pcall(function()
		return cx.session:panes()
	end)
	if ok_p and type(plist) == "table" then
		for _, p in ipairs(plist) do
			if p.tab == tid and (sibling_tid or not owned[p.pane]) then
				to_close[p.pane] = true
			end
		end
	end
	for pid, _ in pairs(to_close) do
		if owned[pid] then
			closing_internally[pid] = true
			persisted.owned_panes[tostring(pid)] = nil
			painted_fp[pid] = nil
			opened_at_ms[pid] = nil
		end
		pcall(function()
			cx.layout:close(pid)
		end)
	end
	synced_tab_ratio[tid] = nil
	last_user_pane_by_tab[tid] = nil
	persisted.marked_tabs[tostring(tid)] = nil
	persisted.fold_tabs[tostring(tid)] = nil
	save_state()
	sync_and_render(cx, true)
end

-- ---------------------------------------------------------------------------
-- Show / Hide / Flip Side / Kanban Group Actions
-- ---------------------------------------------------------------------------
-- Defined with the watcher at the end of the file; a hidden sidebar must not keep timers alive.
local start_watcher: () -> ()
local stop_watcher: () -> ()

local function set_sidebar_visible(cx: WindowCx, visible: boolean)
	persisted.visible = visible
	if not visible then
		picked_skey = nil
		hover_group = nil
		hover_sess_pos = nil
		picked_tab_id = nil
		picked_tab_sess = nil
		hover_tab_pos = nil
	end
	save_state()
	ensure_status_bar(cx)
	if not visible then
		stop_watcher()
		close_all_sidebars(cx)
		pcall(tern.chrome.refresh)
	else
		start_watcher()
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

local function set_session_group(cx: WindowCx, skey: string, group: GroupId, manual: boolean, target_pos: number?)
	if not GROUP_BY_ID[group] then
		return
	end
	local data = collect_data(cx)
	local old_group = persisted.groups[skey]
	persisted.groups[skey] = group
	if manual then
		persisted.manual_groups[skey] = true
	end

	local target_list: { string } = {}
	for _, s in ipairs(data.by_group[group] or {}) do
		if s.skey ~= skey then
			table.insert(target_list, s.skey)
		end
	end
	local ins_pos = if target_pos then clamp(target_pos, 1, #target_list + 1) else (#target_list + 1)
	table.insert(target_list, ins_pos, skey)
	for idx, k in ipairs(target_list) do
		persisted.session_order[k] = idx
	end

	if old_group and old_group ~= group and data.by_group[old_group] then
		local rem_idx = 0
		for _, s in ipairs(data.by_group[old_group]) do
			if s.skey ~= skey then
				rem_idx += 1
				persisted.session_order[s.skey] = rem_idx
			end
		end
	end

	picked_skey = nil
	hover_group = nil
	hover_sess_pos = nil
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
		placeholder = "Move Host / Session to another stage…",
		icon = "kanban",
		action = "move",
		items = items,
	}):next(function(choice, _err, pick_cx)
		if choice and pick_cx and type(choice.skey) == "string" and type(choice.target_group) == "string" then
			set_session_group(pick_cx, choice.skey, choice.target_group :: GroupId, true)
		end
	end)
end

-- "Start in" for a new tab: the tab's own folder when one is given, else the folder the session's
-- shells use most; ties go to the most recently focused pane, i.e. the session's last folder.
local function new_tab_cwd(cx: WindowCx, sess_id: number?, tab_id: number?): string?
	local ok_p, plist = pcall(function()
		return cx.session:panes()
	end)
	if not ok_p or type(plist) ~= "table" then
		return nil
	end
	local function shell_cwd(p: PaneInfo): string?
		local k = p.kind
		if k ~= nil and k ~= "terminal" and k ~= "agent" then
			return nil
		end
		return if type(p.cwd) == "string" and p.cwd ~= "" then p.cwd else nil
	end
	if tab_id then
		local best, best_rank = nil, -2
		for _, p in ipairs(plist) do
			local c = shell_cwd(p)
			if c and p.tab == tab_id then
				local rank = if p.focused then math.huge else (focus_rank[p.pane] or -1)
				if rank > best_rank then
					best, best_rank = c, rank
				end
			end
		end
		return best
	end
	local ok_t, tlist = pcall(function()
		return cx.session:tabs()
	end)
	local in_sess: { [number]: boolean } = {}
	if ok_t and type(tlist) == "table" then
		for _, t in ipairs(tlist) do
			if sess_id == nil or t.session == sess_id then
				in_sess[t.id] = true
			end
		end
	end
	local tally: { [string]: { n: number, rank: number } } = {}
	for _, p in ipairs(plist) do
		local c = shell_cwd(p)
		if c and p.tab ~= nil and in_sess[p.tab] then
			local t = tally[c]
			if not t then
				t = { n = 0, rank = -1 }
				tally[c] = t
			end
			t.n = t.n + 1
			local r = focus_rank[p.pane] or -1
			if r > t.rank then
				t.rank = r
			end
		end
	end
	local best_c, best_t = nil, nil
	for c, t in pairs(tally) do
		if
			best_t == nil
			or t.n > best_t.n
			or (t.n == best_t.n and (t.rank > best_t.rank or (t.rank == best_t.rank and c < best_c)))
		then
			best_c, best_t = c, t
		end
	end
	return best_c
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
		pane_notif[pane_id] = nil
		ack_alerts[pane_id] = true
		if tab_id then
			last_user_pane_by_tab[tab_id] = pane_id
		end
		pcall(function()
			cx.layout:focus(pane_id)
		end)
	elseif tab_id then
		for _, p in ipairs(tab_all_panes(cx, tab_id)) do
			pane_notif[p] = nil
			ack_alerts[p] = true
		end
		local u = first_user_pane(cx, tab_id, owned)
		if u then
			pane_notif[u] = nil
			ack_alerts[u] = true
			last_user_pane_by_tab[tab_id] = u
			pcall(function()
				cx.layout:focus(u)
			end)
		end
	elseif sess_id then
		local ok_t, tlist = pcall(function()
			return cx.session:tabs()
		end)
		if ok_t and type(tlist) == "table" then
			for _, t in ipairs(tlist) do
				if t.session == sess_id then
					for _, p in ipairs(tab_all_panes(cx, t.id)) do
						pane_notif[p] = nil
						ack_alerts[p] = true
					end
				end
			end
		end
	end
	sync_and_render(cx, false)
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean?
	if ev.owner ~= tern.plugin.id then
		return nil
	end
	local cmd, val = parse_action(ev)
	-- Releasing the mouse fires a click a few ms after the drop, on whatever row it landed on;
	-- folding or focusing there would undo the drag the user just made.
	local drag_guard = last_drag_active or (tern.now() - last_drag_end_ms) < 250

	if cmd == "hide_sidebar" then
		set_sidebar_visible(cx, false)
		return true
	elseif cmd == "flip_side" then
		flip_sidebar_side(cx)
		return true
	elseif cmd == "refresh" then
		sync_and_render(cx, true)
		return true
	elseif cmd == "toggle_badge_cfg" then
		badge_cfg_open = not badge_cfg_open
		sync_and_render(cx, true)
		return true
	elseif cmd == "toggle_stage_cfg" then
		stage_cfg_open = not stage_cfg_open
		sync_and_render(cx, true)
		return true
	elseif cmd == "toggle_stage" then
		if GROUP_BY_ID[val] then
			persisted.stage_vis[val] = not (persisted.stage_vis[val] ~= false)
			save_state()
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "toggle_hide_empty" then
		persisted.hide_empty = not persisted.hide_empty
		save_state()
		sync_and_render(cx, true)
		return true
	elseif cmd == "toggle_badge" then
		if val == "total" or val == "running" or val == "idle" or val == "hide_zero" then
			local k = val :: BadgeKey
			persisted.badge_vis[k] = not (persisted.badge_vis[k] ~= false)
			save_state()
			sync_and_render(cx, true)
		end
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
		if drag_guard then
			return true
		end
		if GROUP_BY_ID[val] then
			persisted.fold_groups[val :: GroupId] = not (persisted.fold_groups[val] == true)
			save_state()
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "fold_sess" then
		if drag_guard then
			return true
		end
		if val ~= "" then
			persisted.fold_sessions[val] = not (persisted.fold_sessions[val] == true)
			save_state()
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "fold_tab" then
		if drag_guard then
			return true
		end
		if val ~= "" then
			persisted.fold_tabs[val] = not (persisted.fold_tabs[val] == true)
			save_state()
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "mark_tab" then
		if drag_guard then
			return true
		end
		if val ~= "" then
			if persisted.marked_tabs[val] then
				persisted.marked_tabs[val] = nil
			else
				persisted.marked_tabs[val] = true
			end
			save_state()
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "pick" then
		if last_drag_active or (tern.now() - last_drag_end_ms) < 350 then
			return true
		end
		if val ~= "" then
			picked_tab_id = nil
			picked_tab_sess = nil
			hover_tab_pos = nil
			hover_group = nil
			hover_sess_pos = nil
			if picked_skey == val then
				picked_skey = nil
			else
				picked_skey = val
			end
			sync_and_render(cx, true)
		end
		return true
	elseif cmd == "pick_tab" then
		if last_drag_active or (tern.now() - last_drag_end_ms) < 350 then
			return true
		end
		picked_skey = nil
		hover_group = nil
		hover_sess_pos = nil
		hover_tab_pos = nil
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
			hover_tab_pos = nil
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
		hover_group = nil
		hover_sess_pos = nil
		picked_tab_id = nil
		picked_tab_sess = nil
		hover_tab_pos = nil
		pcall(tern.kv.set, "drag_state", { active = false })
		sync_and_render(cx, true)
		return true
	elseif cmd == "drop_group" then
		if picked_skey and GROUP_BY_ID[val] then
			-- A head drop means "put it first"; nil would append at the end of the group.
			local head_pos = if hover_group == val and hover_sess_pos then hover_sess_pos else 1
			set_session_group(cx, picked_skey, val :: GroupId, true, head_pos)
		end
		return true
	elseif cmd == "drop_sess" then
		local g_str, pos_str = string.match(val, "^(%a+):(%d+)$")
		local target_pos = tonumber(pos_str)
		if picked_skey and g_str and GROUP_BY_ID[g_str] and target_pos then
			set_session_group(cx, picked_skey, g_str :: GroupId, true, target_pos)
		end
		return true
	elseif cmd == "sess_move" then
		local g_str, pos_str, target_skey = string.match(val, "^(%a+):(%d+):(.+)$")
		local target_pos = tonumber(pos_str)
		if target_skey and g_str and GROUP_BY_ID[g_str] and target_pos then
			set_session_group(cx, target_skey, g_str :: GroupId, true, target_pos)
		end
		return true
	elseif cmd == "cycle_group" then
		cycle_session_group(cx, val)
		return true
	elseif cmd == "move_group" then
		local gid, skey = string.match(val, "^(%a+):(.+)$")
		if gid and skey and GROUP_BY_ID[gid] then
			set_session_group(cx, skey, gid :: GroupId, true)
		end
		return true
	elseif cmd == "move_modal" then
		open_move_modal(cx)
		return true
	elseif cmd == "focus_sess" then
		if drag_guard then
			return true
		end
		local sid = tonumber(val)
		if sid then
			focus_session_tab_pane(cx, sid, nil, nil)
		end
		return true
	elseif cmd == "focus_tab" then
		if drag_guard then
			return true
		end
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local sid = tonumber(s_str)
		local tid = tonumber(t_str)
		if sid or tid then
			focus_session_tab_pane(cx, sid, tid, nil)
		end
		return true
	elseif cmd == "focus_pane" then
		if drag_guard then
			return true
		end
		local s_str, t_str, p_str = string.match(val, "^(%d+):(%d+):(%d+)$")
		local sid = tonumber(s_str)
		local tid = tonumber(t_str)
		local pid = tonumber(p_str)
		if pid then
			focus_session_tab_pane(cx, sid, tid, pid)
		end
		return true
	elseif cmd == "new_session" or cmd == "new_session_in" then
		local raw_grp = if val ~= "" then val else "todo"
		local target_grp: GroupId = if GROUP_BY_ID[raw_grp] then (raw_grp :: GroupId) else "todo"
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
		local cwd = new_tab_cwd(cx, nil, nil)
		pcall(function()
			cx.layout:new_tab(if cwd then { cwd = cwd } else nil, { focus = true })
		end)
		sync_and_render(cx, true)
		return true
	elseif cmd == "new_tab_in" then
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local sid = tonumber(s_str) or tonumber(val)
		local tid = tonumber(t_str)
		local cwd = new_tab_cwd(cx, sid, tid)
		pcall(function()
			local ok_cs, cur = pcall(function()
				return cx.sessions:current()
			end)
			if sid and (not ok_cs or not cur or cur.id ~= sid) then
				cx.sessions:switch(sid)
			end
			cx.layout:new_tab(if cwd then { cwd = cwd } else nil, { focus = true })
		end)
		sync_and_render(cx, true)
		return true
	elseif cmd == "new_omp_in" then
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local sid = tonumber(s_str) or tonumber(val)
		local tid = tonumber(t_str)
		local cwd = new_tab_cwd(cx, sid, tid)
		pcall(function()
			local ok_cs, cur = pcall(function()
				return cx.sessions:current()
			end)
			if sid and (not ok_cs or not cur or cur.id ~= sid) then
				cx.sessions:switch(sid)
			end
			cx.layout:new_tab({ command = "omp", cwd = cwd }, { focus = true })
		end)
		sync_and_render(cx, true)
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
		local s_str, t_str = string.match(val, "^(%d+):(%d+)$")
		local tid = tonumber(t_str) or tonumber(val)
		if tid then
			close_tab_safely(cx, tid, tonumber(s_str))
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
	title = "Kanban Sidebar: Move Session to another stage…",
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
local function poll_drag_ipc(cx: WindowCx)
	if busy_lock or not persisted.visible then
		return
	end
	local ok_dd, dd = pcall(tern.kv.get, "drag_drop")
	if ok_dd and type(dd) == "table" and type(dd.seq) == "number" and dd.seq ~= last_drop_seq then
		last_drop_seq = dd.seq
		last_drag_active = false
		last_drag_end_ms = tern.now()
		picked_skey = nil
		hover_group = nil
		hover_sess_pos = nil
		picked_tab_id = nil
		picked_tab_sess = nil
		hover_tab_pos = nil
		-- drag_helper writes drag_state.active = false together with drag_drop.
		if dd.kind == "session" and type(dd.skey) == "string" and type(dd.target_group) == "string" then
			local tpos = if type(dd.target_pos) == "number" then dd.target_pos else nil
			set_session_group(cx, dd.skey, dd.target_group :: GroupId, true, tpos)
		elseif dd.kind == "tab" and type(dd.tab_id) == "number" and type(dd.target_pos) == "number" then
			pcall(function()
				cx.layout:order_tab(dd.tab_id, dd.target_pos)
			end)
			sync_and_render(cx, true)
		end
		return
	end

	local ok_ds, ds = pcall(tern.kv.get, "drag_state")
	local is_active = (ok_ds and type(ds) == "table" and ds.active == true)
	if is_active then
		local new_skey: string? = nil
		local new_hgroup: GroupId? = nil
		local new_hspos: number? = nil
		local new_tid: number? = nil
		local new_tsess: number? = nil
		local new_hpos: number? = nil
		if ds.kind == "session" and type(ds.skey) == "string" then
			new_skey = ds.skey
			if type(ds.hover_group) == "string" and GROUP_BY_ID[ds.hover_group] then
				new_hgroup = ds.hover_group :: GroupId
			end
			new_hspos = if type(ds.hover_pos) == "number" then ds.hover_pos else nil
		elseif ds.kind == "tab" and type(ds.tab_id) == "number" then
			new_tid = ds.tab_id
			new_tsess = if type(ds.sess_id) == "number" then ds.sess_id else nil
			new_hpos = if type(ds.hover_pos) == "number" then ds.hover_pos else nil
		end
		if
			not last_drag_active
			or picked_skey ~= new_skey
			or hover_group ~= new_hgroup
			or hover_sess_pos ~= new_hspos
			or picked_tab_id ~= new_tid
			or picked_tab_sess ~= new_tsess
			or hover_tab_pos ~= new_hpos
		then
			last_drag_active = true
			picked_skey = new_skey
			hover_group = new_hgroup
			hover_sess_pos = new_hspos
			picked_tab_id = new_tid
			picked_tab_sess = new_tsess
			hover_tab_pos = new_hpos
			sync_and_render(cx, false)
		end
	elseif last_drag_active then
		last_drag_active = false
		last_drag_end_ms = tern.now()
		picked_skey = nil
		hover_group = nil
		hover_sess_pos = nil
		picked_tab_id = nil
		picked_tab_sess = nil
		hover_tab_pos = nil
		sync_and_render(cx, true)
	end
end

local drag_timer: TimerHandle? = nil
local watch_timer: TimerHandle? = nil

function stop_watcher()
	if drag_timer then
		drag_timer:cancel()
		drag_timer = nil
	end
	if watch_timer then
		watch_timer:cancel()
		watch_timer = nil
	end
end

local function drag_step(cx: WindowCx?)
	drag_timer = nil
	if not persisted.visible then
		return
	end
	-- Reschedule first: a failing poll must never end the watch loop.
	drag_timer = tern.timer(30, drag_step)
	if cx then
		local ok, err = pcall(poll_drag_ipc, cx)
		if not ok then
			tern.log.warn("sidebar2 drag watcher error:", tostring(err))
		end
	end
end

local function step_body(cx: WindowCx)
	ensure_drag_helper()
	local ok_cs, cur_s = pcall(function()
		return cx.sessions:current()
	end)
	local cur_sid = if ok_cs and cur_s then cur_s.id else nil
	local has_tab = false
	if cur_sid then
		local ok_t, tlist = pcall(function()
			return cx.session:tabs()
		end)
		if ok_t and type(tlist) == "table" then
			for _, t in ipairs(tlist) do
				if t.session == cur_sid then
					has_tab = true
					break
				end
			end
		end
	end
	local f = cx.session:focused()
	local cur_tid = if f then cx.session:tab_of(f) else nil
	-- `not has_tab`: the shown session lost its last tab, so the sync must follow the
	-- sessions that still have tabs instead of sitting on an empty one.
	if not has_tab or cur_sid ~= last_active_session_id or not cur_tid or cur_tid ~= last_active_tab_id then
		sync_and_render(cx, false)
	else
		local data = collect_data(cx)
		local fp = build_fingerprint(data)
		local cur_host = if ok_cs and cur_s then cur_s.host else 0
		local spane = find_host_sidebar(cx, cur_host, data.active_tab_id, data.owned)
		if data.active_tab_id and not spane then
			active_sidebar_pane = nil
			sync_and_render(cx, true)
		elseif spane and (painted_fp[spane] ~= fp or needs_hydration(cx, spane)) then
			sync_and_render(cx, true)
		elseif data.active_tab_id then
			place_sidebar_at_edge(cx, spane, data.active_tab_id, persisted.side, persisted.ratio)
			if cx.session:focused() == spane then
				refocus_terminal(cx, data.active_tab_id, data.owned)
			end
		end
	end
end

-- A safety net, not the fast path: every window event (focus, tab/pane, agent state, title, cwd)
-- syncs at once, so this only has to catch what no event reports.
local function step(cx: WindowCx?)
	watch_timer = nil
	if not persisted.visible then
		return
	end
	-- Reschedule first: one throw must not end the loop; it used to leave the sidebar gone for good.
	watch_timer = tern.timer(1000, step)
	if not (cx and not busy_lock) then
		return
	end
	local ok, err = pcall(step_body, cx)
	if not ok then
		tern.log.warn("sidebar2 watcher error:", tostring(err))
	end
end

function start_watcher()
	if watch_timer then
		return
	end
	if not persisted.visible then
		stop_watcher()
		return
	end
	if not drag_timer then
		drag_timer = tern.timer(30, drag_step)
	end
	watch_timer = tern.timer(1000, step)
end

tern.on("window_start", function(cx: WindowCx)
	ensure_status_bar(cx)
	ensure_drag_helper(true)
	sync_and_render(cx, true)
	start_watcher()
end)

start_watcher()
tern.timer(20, function(cx: WindowCx?)
	if cx then
		ensure_status_bar(cx)
		ensure_drag_helper(true)
		sync_and_render(cx, true)
	end
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if busy_lock then
		return
	end
	pane_notif[ev.pane] = nil
	ack_alerts[ev.pane] = true
	focus_rank_seq = focus_rank_seq + 1
	focus_rank[ev.pane] = focus_rank_seq
	local owned = owned_canvases(cx)
	if not owned[ev.pane] then
		last_user_pane_by_tab[ev.tab] = ev.pane
	end
	if not persisted.visible then
		return
	end
	-- Clicking the canvas must not repaint (that would swallow its context menu); it only needs a
	-- sync when its tab lost every user pane.
	if owned[ev.pane] and ev.tab == last_active_tab_id and first_user_pane(cx, ev.tab, owned) ~= nil then
		return
	end
	sync_and_render(cx, false)
end)

tern.on("agent_state", function(ev: AgentStateEvent, cx: WindowCx)
	if type(ev) == "table" and type(ev.pane) == "number" then
		if ev.new == "waiting_input" then
			pane_notif[ev.pane] = "waiting"
		elseif ev.new == "working" then
			pane_notif[ev.pane] = nil
		elseif ev.old == "working" and ev.new == "idle" then
			if cx.session:focused() ~= ev.pane then
				pane_notif[ev.pane] = "done"
			end
		end
	end
	if not busy_lock and persisted.visible then
		sync_and_render(cx, false)
	end
end)

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	if type(ev) == "table" and type(ev.pane) == "number" then
		if ev.result == "failed" then
			pane_notif[ev.pane] = "error"
		elseif ev.result == "done" and cx.session:focused() ~= ev.pane then
			pane_notif[ev.pane] = "done"
		end
	end
	if not busy_lock and persisted.visible then
		sync_and_render(cx, false)
	end
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if type(ev) == "table" and type(ev.pane) == "number" then
		local pid = ev.pane
		local pkey = tostring(pid)
		if closing_internally[pid] then
			closing_internally[pid] = nil
		elseif
			pid == active_sidebar_pane
			or persisted.owned_panes[pkey]
			or painted_fp[pid] ~= nil
			or opened_at_ms[pid] ~= nil
		then
			-- The tab closed the canvas with it (native × on the tab): forget it and let the sync
			-- below remount the sidebar on the active tab, still at the pinned edge and ratio.
			closing_internally[pid] = nil
			if pid == active_sidebar_pane then
				active_sidebar_pane = nil
			end
			persisted.owned_panes[pkey] = nil
			painted_fp[pid] = nil
			painted_sec_fp[pid] = nil
			opened_at_ms[pid] = nil
			focus_rank[pid] = nil
			save_state()
		end
	end
	if not busy_lock and persisted.visible then
		sync_and_render(cx, true)
	end
end)

for _, ev_name in ipairs({
	"tab_created",
	"tab_closed",
	"pane_created",
	"command_started",
	"command_finished",
	"title",
	"cwd",
	"session_ended",
}) do
	tern.on(ev_name, function(_ev: any, cx: WindowCx)
		if not busy_lock and persisted.visible then
			sync_and_render(cx, false)
		end
	end)
end

-- Built-in closes must not drag the canvas into another tab's right half, nor close it at all.
pcall(tern.override, "close_tab", function(cx: WindowCx): boolean?
	if busy_lock or not persisted.visible then
		return nil
	end
	local f = cx.session:focused()
	local tid = last_active_tab_id or (if f then cx.session:tab_of(f) else nil)
	if not tid then
		return nil
	end
	close_tab_safely(cx, tid, last_active_session_id)
	return true
end)

pcall(tern.override, "close_pane", function(cx: WindowCx): boolean?
	if busy_lock or not persisted.visible then
		return nil
	end
	local f = cx.session:focused()
	if not f then
		return nil
	end
	local owned = owned_canvases(cx)
	if not owned[f] then
		return nil
	end
	local tid = cx.session:tab_of(f)
	local u = if tid then first_user_pane(cx, tid, owned) else nil
	if not u then
		return nil
	end
	pcall(function()
		cx.layout:close(u)
	end)
	return true
end)
