--!strict
-- Run with `luau tests/metrics.test.luau` from the repository root.
local metrics = require("../metrics")

local failures = 0
local function check(name: string, cond: boolean, detail: any?)
	if not cond then
		failures += 1
		print("FAIL " .. name .. (if detail ~= nil then ": " .. tostring(detail) else ""))
	end
end

local function near(a: number?, b: number, eps: number): boolean
	return a ~= nil and math.abs(a - b) <= eps
end

-- macOS, captured from a real `sh -c` run of the collector script.
local mac = metrics.sections(require("./fixtures/macos"))

local cpu = metrics.mac_cpu(mac.cpu)
check("mac cpu parses", cpu ~= nil)
if cpu then
	check("mac cpu busy = 100 - idle", near(cpu.busy, 100 - 65, 0.01), cpu.busy)
	check("mac cpu user/sys", cpu.user == 16 and cpu.sys == 19)
	check("mac load", cpu.load ~= nil and near(cpu.load[1], 5.94, 1e-9))
end

local mem = metrics.mac_mem(mac.vm, mac.memsize)
check("mac mem parses", mem ~= nil)
if mem then
	-- (anonymous 228637 - purgeable 18 + wired 294720 + compressor 370783) * 16384
	check("mac mem used", mem.used == 894122 * 16384, mem.used)
	check("mac mem total", mem.total == 17179869184)
end

local disk = metrics.df(mac.df)
check("mac disk parses", disk ~= nil)
if disk then
	check("mac disk used/avail", disk.used == 455753200 * 1024 and disk.free == 27044452 * 1024)
	-- df prints 95% for this line: Capacity rounds up
	check("mac disk pct matches df", disk.pct == 95, disk.pct)
	check("mac disk size", disk.size == 482797652 * 1024)
end

local batt = metrics.mac_battery(mac.batt)
check("mac battery charged", batt ~= nil and batt.percent == 100 and batt.state == "charged" and batt.remaining == nil)

local discharging = metrics.mac_battery(
	"Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t18%; discharging; 1:07 remaining present: true"
)
check("mac battery discharging", discharging ~= nil and discharging.state == "discharging" and discharging.remaining == "1:07")
check("battery tone low", discharging ~= nil and metrics.battery_tone(discharging) == "warn")
local estimating = metrics.mac_battery(" -InternalBattery-0 (id=1)\t64%; charging; (no estimate) present: true")
check("mac battery no estimate", estimating ~= nil and estimating.state == "charging" and estimating.remaining == nil)
local not_charging = metrics.mac_battery(" -InternalBattery-0 (id=1)\t80%; AC attached; not charging present: true")
check("mac battery AC not charging", not_charging ~= nil and not_charging.state == "ac")
check("mac desktop has no battery", metrics.mac_battery("Now drawing from 'AC Power'\n") == nil)

-- A device name and mount point with spaces.
local spaced = metrics.df("Filesystem 1024-blocks Used Available Capacity Mounted on\nmy disk 1000 250 750 25% /Volumes/My Disk")
check("df with spaces", spaced ~= nil and spaced.used == 250 * 1024 and spaced.size == 1000 * 1024 and spaced.pct == 25)

-- Linux.
local stat = "cpu  100 0 50 800 50 0 0 0 0 0\ncpu  130 0 60 850 60 0 0 0 0 0"
local lcpu = metrics.linux_cpu(stat, "0.52 0.58 0.59 1/389 12345\n")
check("linux cpu parses", lcpu ~= nil)
if lcpu then
	-- dt = 100, idle+iowait = 60 -> busy 40, user 30, sys 10
	check("linux cpu busy", near(lcpu.busy, 40, 1e-9), lcpu.busy)
	check("linux cpu user/sys", near(lcpu.user, 30, 1e-9) and near(lcpu.sys, 10, 1e-9))
	check("linux load", lcpu.load ~= nil and near(lcpu.load[3], 0.59, 1e-9))
end
check("linux cpu needs two reads", metrics.linux_cpu("cpu  1 2 3 4", nil) == nil)

local lmem = metrics.linux_mem("MemTotal:       16000000 kB\nMemFree:  1000 kB\nMemAvailable:   6000000 kB\nSlab: 500000 kB\n")
check("linux mem used", lmem ~= nil and lmem.used == 10000000 * 1024 and lmem.wired == 500000 * 1024)

local lbatt = metrics.linux_battery("57\nDischarging\n")
check("linux battery", lbatt ~= nil and lbatt.percent == 57 and lbatt.state == "discharging")
local lnot = metrics.linux_battery("100\nNot charging\n")
check("linux battery not charging", lnot ~= nil and lnot.state == "ac")

-- Formatting.
check("spark scale", metrics.spark({ 0, 50, 100 }, 8) == "▁▅█", metrics.spark({ 0, 50, 100 }, 8))
check("spark keeps the last n", metrics.spark({ 100, 0, 0 }, 2) == "▁▁")
check("tone bands", metrics.tone(74.9) == "muted" and metrics.tone(75) == "warn" and metrics.tone(90) == "error")
check("pct rounds", metrics.pct(7.6) == " 8%" and metrics.pct(100) == "100%", metrics.pct(7.6))
check("bytes", metrics.bytes(894122 * 16384) == "13.6 GB", metrics.bytes(894122 * 16384))

if failures > 0 then
	error(failures .. " check(s) failed")
end
print("ok")
