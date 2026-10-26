--!strict
-- Pure parsers and formatters for vitals: no `tern` global, so plain `luau`
-- can run them against captured command output (see tests/).

local M = {}

export type Cpu = {
	busy: number, -- percent, 0-100
	user: number,
	sys: number,
	load: { number }?, -- 1, 5 and 15 minute load averages
}

export type Mem = {
	total: number, -- bytes
	used: number, -- bytes: app + wired + compressed (Activity Monitor's "Memory Used")
	app: number,
	wired: number,
	compressed: number,
}

export type Disk = {
	size: number, -- bytes, df's Size
	used: number,
	free: number,
	pct: number, -- df's Capacity: used / (used + available), rounded up
}

export type Battery = {
	percent: number,
	state: string, -- "charging" | "discharging" | "charged" | "ac" (plugged in, not charging)
	remaining: string?, -- "3:12" while an estimate exists
}

export type Sample = {
	cpu: Cpu?,
	mem: Mem?,
	disk: Disk?,
	battery: Battery?,
}

-- Splits the collector script's output into sections introduced by `@name` lines.
function M.sections(text: string): { [string]: string }
	local out: { [string]: string } = {}
	local name: string? = nil
	local buf: { string } = {}
	local function flush()
		if name ~= nil then
			out[name] = table.concat(buf, "\n")
		end
		buf = {}
	end
	for line in string.gmatch(text, "([^\n]*)\n?") do
		local header = string.match(line, "^@([%w_]+)%s*$")
		if header ~= nil then
			flush()
			name = header
		elseif name ~= nil then
			table.insert(buf, line)
		end
	end
	flush()
	return out
end

local function clamp_pct(x: number): number
	return math.max(0, math.min(100, x))
end

-- macOS: the last data line of `iostat -c 2 -w 1 -n 0`:
-- " 16 19 65  5.94 6.58 7.55" (us sy id, then the load averages).
-- The first line averages since boot; the collector keeps only the second.
function M.mac_cpu(text: string?): Cpu?
	if text == nil then
		return nil
	end
	local us, sy, id, l1, l5, l15 =
		string.match(text, "^%s*(%d+)%s+(%d+)%s+(%d+)%s+([%d.]+)%s+([%d.]+)%s+([%d.]+)")
	if id == nil then
		return nil
	end
	return {
		busy = clamp_pct(100 - (tonumber(id) :: number)),
		user = tonumber(us) :: number,
		sys = tonumber(sy) :: number,
		load = { tonumber(l1) :: number, tonumber(l5) :: number, tonumber(l15) :: number },
	}
end

local function vm_pages(text: string, label: string): number?
	local n = string.match(text, label .. ":%s+(%d+)")
	return if n ~= nil then tonumber(n) else nil
end

-- macOS: `vm_stat` plus `sysctl -n hw.memsize`. "Memory Used" in Activity
-- Monitor is App Memory + Wired + Compressed, where App Memory is the
-- anonymous pages that aren't purgeable.
function M.mac_mem(vm_stat: string?, memsize: string?): Mem?
	if vm_stat == nil or memsize == nil then
		return nil
	end
	local page = tonumber(string.match(vm_stat, "page size of (%d+) bytes") or "")
	local total = tonumber(string.match(memsize, "(%d+)") or "")
	local anon = vm_pages(vm_stat, "Anonymous pages")
	local purgeable = vm_pages(vm_stat, "Pages purgeable") or 0
	local wired = vm_pages(vm_stat, "Pages wired down")
	local compressor = vm_pages(vm_stat, "Pages occupied by compressor")
	if page == nil or total == nil or total <= 0 or anon == nil or wired == nil or compressor == nil then
		return nil
	end
	local app = math.max(0, anon - purgeable) * page
	local w = wired * page
	local c = compressor * page
	return { total = total, used = math.min(total, app + w + c), app = app, wired = w, compressed = c }
end

-- Both OSes: the data line of `df -kP <path>`. Mount points and device
-- names may hold spaces, so match the three numbers before the capacity
-- (blocks, used, available).
function M.df(text: string?): Disk?
	if text == nil then
		return nil
	end
	for line in string.gmatch(text, "[^\n]+") do
		local blocks, used, avail = string.match(line, "%s(%d+)%s+(%d+)%s+(%d+)%s+%d+%%")
		if blocks ~= nil and used ~= nil and avail ~= nil then
			local u = tonumber(used) :: number
			local a = tonumber(avail) :: number
			if u + a > 0 then
				return {
					size = (tonumber(blocks) :: number) * 1024,
					used = u * 1024,
					free = a * 1024,
					pct = math.ceil(100 * u / (u + a)),
				}
			end
		end
	end
	return nil
end

-- macOS: `pmset -g batt`. Desktops print no InternalBattery line.
-- " -InternalBattery-0 (id=36962403)	84%; discharging; 3:12 remaining present: true"
function M.mac_battery(text: string?): Battery?
	if text == nil then
		return nil
	end
	local line = string.match(text, "InternalBattery[^\n]*")
	if line == nil then
		return nil
	end
	local pct, raw = string.match(line, "(%d+)%%;%s*([^;]+);")
	if pct == nil or raw == nil then
		return nil
	end
	local state: string
	if raw == "charging" or raw == "finishing charge" then
		state = "charging"
	elseif raw == "discharging" then
		state = "discharging"
	elseif raw == "charged" then
		state = "charged"
	else
		state = "ac" -- "AC attached; not charging"
	end
	local remaining = string.match(line, "(%d+:%d%d) remaining")
	if remaining == "0:00" then
		remaining = nil
	end
	return { percent = clamp_pct(tonumber(pct) :: number), state = state, remaining = remaining }
end

local function cpu_ticks(line: string): (number?, number?, number?, number?)
	local fields: { number } = {}
	for n in string.gmatch(line, "%d+") do
		table.insert(fields, tonumber(n) :: number)
	end
	if #fields < 4 then
		return nil
	end
	-- user nice system idle iowait irq softirq steal (guest time is already in user)
	local total = 0
	for i = 1, math.min(#fields, 8) do
		total += fields[i]
	end
	local idle = fields[4] + (fields[5] or 0)
	return total, idle, fields[1] + fields[2], fields[3] + (fields[6] or 0) + (fields[7] or 0)
end

-- Linux: two aggregate `cpu` lines of /proc/stat taken a second apart,
-- and /proc/loadavg.
function M.linux_cpu(stat: string?, loadavg: string?): Cpu?
	if stat == nil then
		return nil
	end
	local lines: { string } = {}
	for line in string.gmatch(stat, "cpu%s[^\n]*") do
		table.insert(lines, line)
	end
	if #lines < 2 then
		return nil
	end
	local t0, i0, u0, s0 = cpu_ticks(lines[1])
	local t1, i1, u1, s1 = cpu_ticks(lines[2])
	if t0 == nil or t1 == nil or i0 == nil or i1 == nil or u0 == nil or u1 == nil or s0 == nil or s1 == nil then
		return nil
	end
	local dt = t1 - t0
	if dt <= 0 then
		return nil
	end
	local load: { number }? = nil
	if loadavg ~= nil then
		local a, b, c = string.match(loadavg, "^%s*([%d.]+)%s+([%d.]+)%s+([%d.]+)")
		if a ~= nil then
			load = { tonumber(a) :: number, tonumber(b) :: number, tonumber(c) :: number }
		end
	end
	return {
		busy = clamp_pct(100 * (dt - (i1 - i0)) / dt),
		user = clamp_pct(100 * (u1 - u0) / dt),
		sys = clamp_pct(100 * (s1 - s0) / dt),
		load = load,
	}
end

local function meminfo_kb(text: string, key: string): number?
	local n = string.match(text, key .. ":%s+(%d+)")
	return if n ~= nil then (tonumber(n) :: number) * 1024 else nil
end

-- Linux: /proc/meminfo. Used is MemTotal - MemAvailable; the split shows
-- unevictable kernel memory as "wired" so the dashboard's parts add up.
function M.linux_mem(text: string?): Mem?
	if text == nil then
		return nil
	end
	local total = meminfo_kb(text, "MemTotal")
	local avail = meminfo_kb(text, "MemAvailable")
	if total == nil or avail == nil or total <= 0 then
		return nil
	end
	local used = math.max(0, total - avail)
	local kernel = (meminfo_kb(text, "Slab") or 0) + (meminfo_kb(text, "KernelStack") or 0) + (meminfo_kb(text, "PageTables") or 0)
	local wired = math.min(used, kernel)
	return { total = total, used = used, app = used - wired, wired = wired, compressed = 0 }
end

-- Linux: `capacity` and `status` of the first /sys/class/power_supply entry
-- whose type is Battery, one per line.
function M.linux_battery(text: string?): Battery?
	if text == nil then
		return nil
	end
	local pct, status = string.match(text, "^%s*(%d+)%s+(%a[%a ]*%a)")
	if pct == nil or status == nil then
		return nil
	end
	local s = string.lower(status)
	local state = if s == "charging"
		then "charging"
		elseif s == "discharging" then "discharging"
		elseif s == "full" then "charged"
		else "ac"
	return { percent = clamp_pct(tonumber(pct) :: number), state = state, remaining = nil }
end

local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- The last `n` values (percentages) as block characters on an absolute
-- 0-100 scale.
function M.spark(values: { number }, n: number): string
	local out: { string } = {}
	for i = math.max(1, #values - n + 1), #values do
		local level = math.floor(clamp_pct(values[i]) / 100 * 7 + 0.5) + 1
		table.insert(out, BLOCKS[level])
	end
	return table.concat(out)
end

-- Status segment tone for a load percentage.
function M.tone(pct: number): string
	if pct >= 90 then
		return "error"
	elseif pct >= 75 then
		return "warn"
	end
	return "muted"
end

-- Status segment tone for a battery.
function M.battery_tone(b: Battery): string
	if b.state == "discharging" then
		if b.percent <= 10 then
			return "error"
		elseif b.percent <= 20 then
			return "warn"
		end
		return "muted"
	elseif b.state == "charging" then
		return "ok"
	end
	return "muted"
end

-- A percentage, padded to two digits so the status line jitters less.
function M.pct(x: number): string
	return string.format("%2.0f%%", clamp_pct(x))
end

-- Bytes in binary units as Activity Monitor writes them: "12.4 GB".
function M.bytes(n: number): string
	local units = { "B", "KB", "MB", "GB", "TB", "PB" }
	local i = 1
	while n >= 1024 and i < #units do
		n /= 1024
		i += 1
	end
	if i == 1 or n >= 100 then
		return string.format("%.0f %s", n, units[i])
	end
	return string.format("%.1f %s", n, units[i])
end

return M
