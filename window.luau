--!strict
-- vitals, window half: CPU, memory, disk and battery in the status line,
-- iTerm-style, and a live "System Vitals" canvas opened by clicking a
-- segment or the palette command.
--
-- Each window runs its own copy of this file, so each window polls. A poll
-- is one `/bin/sh -c` spawn; everything the formatter returns is built in
-- the process callback, so the formatter itself only hands back a table.

local metrics = require("./metrics")

-- How often to sample, in milliseconds. The CPU reading itself covers the
-- last second (iostat / two /proc/stat reads), so keep this >= 1500.
local INTERVAL_MS = 2000
-- Samples kept for the graphs, and how many the status line shows.
local HISTORY = 30
local STATUS_SPARK = 8
-- A collector run that takes longer than this is killed; the loop goes on.
local TIMEOUT_MS = 8000

local ACTION = "plugin.vitals.open"
local DASH_TITLE = "System Vitals"
-- Which window keeps the dashboard updated: one lease in tern.kv, renewed
-- every LEASE_RENEW_S by its holder and taken over once LEASE_TTL_S passes.
local LEASE_KEY = "dashboard_lease"
local LEASE_RENEW_S = 5
local LEASE_TTL_S = 15

local MAC_SCRIPT = table.concat({
	"echo @vm; /usr/bin/vm_stat",
	"echo @memsize; /usr/sbin/sysctl -n hw.memsize",
	-- `/` is the sealed system snapshot on APFS; user data lives on the Data volume.
	"echo @df; /bin/df -kP /System/Volumes/Data 2>/dev/null || /bin/df -kP /",
	"echo @batt; /usr/bin/pmset -g batt",
	-- The second iostat line covers the last second; the first is since boot.
	"echo @cpu; /usr/sbin/iostat -c 2 -w 1 -n 0 | /usr/bin/tail -n 1",
}, "\n")

local LINUX_SCRIPT = table.concat({
	"echo @meminfo; cat /proc/meminfo",
	"echo @loadavg; cat /proc/loadavg",
	"echo @df; df -kP /",
	"for d in /sys/class/power_supply/*; do",
	'  if [ "$(cat "$d/type" 2>/dev/null)" = Battery ]; then echo @batt; cat "$d/capacity" "$d/status"; break; fi',
	"done",
	"echo @stat; head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat",
}, "\n")

local OS = tern.runtime.os
local SCRIPT: string? = if OS == "macos" then MAC_SCRIPT elseif OS == "linux" then LINUX_SCRIPT else nil

-- What the formatter returns, rebuilt after every sample; nil until the first.
local segments: { StatusSegment }? = nil
local latest: metrics.Sample = {}
local history: { cpu: { number }, mem: { number } } = { cpu = {}, mem = {} }
local last_error: string? = nil
local vm_id = string.format("%x-%x", math.floor(os.clock() * 1e6), math.random(1, 0x7fffffff))

local function push(buf: { number }, v: number)
	table.insert(buf, v)
	if #buf > HISTORY then
		table.remove(buf, 1)
	end
end

local function parse(stdout: string): metrics.Sample
	local s = metrics.sections(stdout)
	if OS == "macos" then
		return {
			cpu = metrics.mac_cpu(s.cpu),
			mem = metrics.mac_mem(s.vm, s.memsize),
			disk = metrics.df(s.df),
			battery = metrics.mac_battery(s.batt),
		}
	end
	return {
		cpu = metrics.linux_cpu(s.stat, s.loadavg),
		mem = metrics.linux_mem(s.meminfo),
		disk = metrics.df(s.df),
		battery = metrics.linux_battery(s.batt),
	}
end

local function mem_pct(m: metrics.Mem): number
	return 100 * m.used / m.total
end

-- "CPU 23% ▂▃▅", or just "CPU 23%" with STATUS_SPARK = 0.
local function with_spark(label: string, pct: number, values: { number }): string
	local graph = if STATUS_SPARK > 0 then metrics.spark(values, STATUS_SPARK) else ""
	local text = label .. " " .. metrics.pct(pct)
	return if graph ~= "" then text .. " " .. graph else text
end

local function build_segments(s: metrics.Sample): { StatusSegment }?
	local out: { StatusSegment } = {}
	if s.cpu then
		table.insert(out, {
			text = with_spark("CPU", s.cpu.busy, history.cpu),
			tone = metrics.tone(s.cpu.busy),
			command = ACTION,
		})
	end
	if s.mem then
		local p = mem_pct(s.mem)
		table.insert(out, {
			text = with_spark("RAM", p, history.mem),
			tone = metrics.tone(p),
			command = ACTION,
		})
	end
	if s.disk then
		local p = s.disk.pct
		table.insert(out, { text = "Disk " .. metrics.pct(p), tone = metrics.tone(p), command = ACTION })
	end
	local b = s.battery
	if b then
		local text = "BAT " .. metrics.pct(b.percent)
		if b.state == "discharging" and b.remaining then
			text ..= " " .. b.remaining
		end
		table.insert(out, {
			text = text,
			icon = if b.state == "charging" or b.state == "ac" or b.state == "charged" then "bolt" else nil,
			tone = metrics.battery_tone(b),
			command = ACTION,
		})
	end
	return if #out > 0 then out else nil
end

-- Dashboard ------------------------------------------------------------------

local ui = tern.ui

local function spark(values: { number }, token: string): Node
	local series: { { value: number, title: string? } } = {}
	for i, v in values do
		series[i] = { value = math.max(v, 0.5), title = metrics.pct(v) }
	end
	-- Pad to a fixed width so bars don't resize while the history fills up.
	for i = #series + 1, HISTORY do
		table.insert(series, 1, { value = 0 })
	end
	return ui.node("chart", { kind = "spark", token = token, series = series, role = "vitals.spark", grow = 1 })
end

local function meter(value: number, label: string, total: string?, parts: { any }?): Node
	return ui.node("meter", {
		value = value / 100,
		parts = parts,
		thresholds = { warn = 0.75, bad = 0.9 },
		size = "md",
		label = label,
		total = total,
		role = "vitals.meter",
	})
end

local function muted(text: string): Node
	return ui.text({ ui.span(text, "muted") })
end

local function dashboard_view(): Node
	local s = latest
	local cards: { Node } = {}
	local cpu = s.cpu
	if cpu then
		local detail = string.format("user %s · sys %s", metrics.pct(cpu.user), metrics.pct(cpu.sys))
		if cpu.load then
			detail ..= string.format(" · load %.2f %.2f %.2f", cpu.load[1], cpu.load[2], cpu.load[3])
		end
		table.insert(cards, ui.card("CPU", {
			meter(cpu.busy, metrics.pct(cpu.busy)),
			spark(history.cpu, "accent"),
			muted(detail),
		}))
	end
	local mem = s.mem
	if mem then
		local p = mem_pct(mem)
		local parts = {
			{ value = mem.app / mem.total, token = "info", label = "app " .. metrics.bytes(mem.app) },
			{ value = mem.wired / mem.total, token = "warning", label = "wired " .. metrics.bytes(mem.wired) },
			{ value = mem.compressed / mem.total, token = "muted", label = "compressed " .. metrics.bytes(mem.compressed), hatch = true },
		}
		local detail = string.format("app %s · wired %s", metrics.bytes(mem.app), metrics.bytes(mem.wired))
		if mem.compressed > 0 then
			detail ..= " · compressed " .. metrics.bytes(mem.compressed)
		end
		table.insert(cards, ui.card("Memory", {
			meter(p, metrics.pct(p), metrics.bytes(mem.used) .. " / " .. metrics.bytes(mem.total), parts),
			spark(history.mem, "info"),
			muted(detail),
		}))
	end
	local disk = s.disk
	if disk then
		local p = disk.pct
		table.insert(cards, ui.card("Disk", {
			meter(p, metrics.pct(p), metrics.bytes(disk.used) .. " / " .. metrics.bytes(disk.size)),
			muted(metrics.bytes(disk.free) .. " free"),
		}))
	end
	local b = s.battery
	if b then
		local detail = b.state
		if b.remaining then
			detail ..= " · " .. b.remaining .. (if b.state == "charging" then " to full" else " left")
		end
		table.insert(cards, ui.card("Battery", {
			ui.node("meter", {
				value = b.percent / 100,
				size = "md",
				label = metrics.pct(b.percent),
				tone = if b.state == "discharging" and b.percent <= 20 then "error" else "success",
				role = "vitals.meter",
			}),
			muted(detail),
		}))
	end
	if #cards == 0 then
		table.insert(cards, muted("Waiting for the first sample…"))
	end
	return ui.node("col", { key = "root", role = "vitals.dashboard" }, cards)
end

-- This plugin's dashboard canvas, if one exists anywhere this window can see.
local function find_dashboard(cx: WindowCx): number?
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id then
			return canvas.pane
		end
	end
	return nil
end

-- Whether this window should push updates to the dashboard, renewing or
-- taking the lease as needed. kv is shared by every window's window half.
local function hold_lease(): boolean
	local now = os.time()
	local lease = tern.kv.get(LEASE_KEY)
	local mine = type(lease) == "table" and lease.vm == vm_id
	local fresh = type(lease) == "table" and type(lease.t) == "number" and now - lease.t < LEASE_TTL_S
	if fresh and not mine then
		return false
	end
	if not mine or now - lease.t >= LEASE_RENEW_S then
		tern.kv.set(LEASE_KEY, { vm = vm_id, t = now })
	end
	return true
end

local function update_dashboard(cx: WindowCx)
	local pane = find_dashboard(cx)
	if pane ~= nil and hold_lease() then
		cx.canvas:set(pane, { view = dashboard_view() })
	end
end

local function open_dashboard(cx: WindowCx)
	local pane = find_dashboard(cx)
	if pane ~= nil then
		cx.layout:focus(pane)
		return
	end
	local opened, err = cx.canvas:open({
		title = DASH_TITLE,
		about = "Live CPU, memory, disk and battery from the vitals plugin, sampled every "
			.. string.format("%.0f", INTERVAL_MS / 1000)
			.. " s.",
		view = dashboard_view(),
		how = "beside",
	})
	if opened == nil then
		cx:toast("error", "System Vitals not opened", err)
		return
	end
	tern.kv.set(LEASE_KEY, { vm = vm_id, t = os.time() })
end

-- Poll loop ------------------------------------------------------------------

local function report(err: any)
	local msg = tostring(err)
	if msg ~= last_error then
		last_error = msg
		tern.log.warn("vitals: " .. msg)
	end
end

local function on_result(result: ProcessResult, cx: WindowCx?)
	if result.timed_out then
		report("collector timed out after " .. TIMEOUT_MS .. " ms")
		return
	end
	local s = parse(result.stdout)
	if s.cpu == nil and s.mem == nil and s.disk == nil then
		report("collector printed nothing usable (status " .. result.status .. "): " .. string.sub(result.stderr, 1, 200))
		return
	end
	last_error = nil
	if s.cpu then
		push(history.cpu, s.cpu.busy)
	end
	if s.mem then
		push(history.mem, mem_pct(s.mem))
	end
	-- One failed command (a killed iostat) keeps its metric's last value
	-- rather than dropping the segment for a tick. Battery stays as read:
	-- nil there means there is none.
	latest = {
		cpu = s.cpu or latest.cpu,
		mem = s.mem or latest.mem,
		disk = s.disk or latest.disk,
		battery = s.battery,
	}
	segments = build_segments(latest)
	tern.chrome.refresh()
	if cx ~= nil then
		update_dashboard(cx)
	end
end

local poll: (cx: WindowCx?) -> ()

local function schedule(delay: number)
	tern.timer(math.max(0, delay), poll)
end

poll = function(_cx: WindowCx?)
	local script = SCRIPT :: string
	local started = tern.now()
	local ok, err = pcall(function()
		tern.process.run({ "/bin/sh", "-c", script }, { timeout_ms = TIMEOUT_MS }, function(result: ProcessResult, cx: WindowCx?)
			local handled, why = pcall(on_result, result, cx)
			if not handled then
				report(why)
			end
			-- Every path re-arms: a timeout, a parse error, a failed refresh.
			schedule(INTERVAL_MS - (tern.now() - started))
		end)
	end)
	if not ok then
		-- The shell couldn't even start; back off instead of spinning.
		report(err)
		schedule(INTERVAL_MS * 5)
	end
end

-- Registration ---------------------------------------------------------------

tern.command({
	id = "open",
	title = "Open System Vitals",
	icon = "activity",
	run = open_dashboard,
})

tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return segments
end)

-- tern.process raises on iOS, and Windows has no collector yet.
if SCRIPT ~= nil then
	poll(nil)
end
