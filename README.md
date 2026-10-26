# tern-vitals

iTerm-style system stats for [Tern](https://docs.stencil.so/tern/): CPU, memory, disk and battery in the
status line, with mini graphs, and a live **System Vitals** dashboard one click away.

```
CPU 23% ▂▃▅▄▃▂▃▅   RAM 61% ▅▅▅▅▆▆▆▆   Disk 48%   ⚡ BAT 84%
```

- **CPU**: busy share over the last second, with the last 8 samples as a sparkline.
- **RAM**: Activity Monitor's "Memory Used" (app + wired + compressed) over physical memory.
- **Disk**: the Data volume's capacity, as `df -h` prints it.
- **Battery**: charge, a bolt while on power, time left while discharging. Hidden on Macs without one.

Segments turn `warn` at 75% and `error` at 90% (battery: 20% and 10% while discharging). Click any of
them, or run **Open System Vitals** from the palette, for the dashboard: a meter per metric, the memory
split into app / wired / compressed, load averages and 30-sample CPU and memory graphs.

macOS and Linux. It does nothing on Windows and iOS.

## Install

```sh
tern plugin install github.com/MattiaFailla/tern-vitals
```

or, from a clone you want to edit (Tern reloads it when files change):

```sh
git clone https://github.com/MattiaFailla/tern-vitals ~/w/tern-vitals
tern plugin link ~/w/tern-vitals
```

`tern plugin list` should show `vitals … window  ready`.

**Turn the status bar on**: plugin segments only show while it is visible. If there is no line at
the bottom of the window, run **Show status line** (the `status_bar` action) from the palette.
The first values appear about a second after loading.

## Configuration

The knobs are constants at the top of `window.luau`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `INTERVAL_MS` | `2000` | Time between samples. Each CPU reading covers one second, so keep it at 1500 or more. |
| `STATUS_SPARK` | `8` | Sparkline length in the status line. `0` hides the graphs. |
| `HISTORY` | `30` | Samples kept for the dashboard graphs. |
| `TIMEOUT_MS` | `8000` | A collector run taking longer is killed; the next sample goes ahead as usual. |

With `tern plugin link`, saving the file reloads the plugin. With `tern plugin install`, edit the copy
under `tern plugin dir` and run `tern plugin reload`.

## How it works

The plugin is a window half only (no host entry). Every `INTERVAL_MS` each window runs **one**
`/bin/sh -c` script through `tern.process.run` and parses its output off the formatter path:

| Metric | macOS | Linux |
| --- | --- | --- |
| CPU | second line of `iostat -c 2 -w 1 -n 0` (the first is since boot) | two `/proc/stat` reads a second apart |
| Load | the same `iostat` line | `/proc/loadavg` |
| Memory | `vm_stat` (anonymous − purgeable + wired + compressor pages) × page size ÷ `hw.memsize` | `MemTotal − MemAvailable` from `/proc/meminfo` |
| Disk | `df -kP /System/Volumes/Data` (`/` is the sealed system snapshot on APFS) | `df -kP /` |
| Battery | `pmset -g batt` | the first `/sys/class/power_supply/*` whose `type` is `Battery` |

The status segments are built in the process callback, so the status formatter only returns a cached
table and stays far inside its 4 ms budget. The timer is re-armed on every path (success, timeout, a
parse error, a spawn failure with a 5× back-off), and one failed command keeps its metric's last value
instead of blanking the segment. Errors are logged once per distinct message as `vitals: …` in Tern's
log (Settings › Advanced › Open logs).

The dashboard is a `cx.canvas` pane, so it needs no host half and survives reloads. Every window
samples on its own; one window at a time (a lease in `tern.kv`, renewed every 5 s) pushes the
dashboard updates, and another takes over 15 s after that window closes.

## Development

```sh
luau tests/metrics.test.luau          # parsers and formatters against captured output
tern plugin types .                   # writes tern.d.luau for this Tern build
luau-lsp analyze --definitions=tern.d.luau window.luau metrics.luau tests/metrics.test.luau
```

`metrics.luau` holds every parser and formatter and doesn't touch the `tern` global, so plain `luau`
runs its tests. `window.luau` holds the poll loop, the status formatter and the dashboard.

## License

MIT
