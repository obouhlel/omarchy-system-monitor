# System monitor

An [Omarchy](https://omarchy.org) bar widget that keeps CPU, RAM, GPU and VRAM
usage permanently in view: four small pill gauges with the figure inside, and a
detail card on hover.

A full VRAM is what stops the shell from allocating its surfaces and takes the
bar down with it, so this is the number worth watching while gaming, running a
local model or rendering.

## Install

```bash
omarchy plugin add https://github.com/obouhlel/omarchy-system-monitor.git --enable
```

Run `omarchy restart shell` if you reinstalled over an older version.

## Uninstall

```bash
omarchy plugin remove obouhlel.sysmon
```

## What it shows

- **Bar**: `CPU`, `RAM`, `GPU`, `VRAM`, each as a percentage in a pill that
  fills up. The fill uses the bar text colour, turns to a halfway colour 25
  points below the urgent threshold, and to the theme's urgent colour at the
  threshold. Every colour comes from your theme.
- **Hover card**: the same readings as bars, plus CPU temperature, RAM and VRAM
  in GB, GPU temperature and power draw, swap usage and the GPU's name.

GPU readings come from `nvidia-smi` on NVIDIA and from sysfs on AMD. On a
machine with neither, the GPU and VRAM gauges simply don't appear.

## Clicks

| Click  | Action |
| ------ | ------ |
| Left   | Opens `btop` |
| Right  | Drops the page cache (`echo 3 > /proc/sys/vm/drop_caches`), which asks for your `sudo` password |
| Middle | Runs the bundled [`bin/vram-clean`](bin/vram-clean) — NVIDIA only, hidden elsewhere |

`vram-clean` lists the processes holding VRAM and closes the ones you pick (via
`gum`). On NVIDIA there is no other way to give memory back. Hyprland,
quickshell, Xwayland, portals and terminals are protected and never offered.
It also works on its own: `bin/vram-clean --list` shows the state without
killing anything.

## Settings

Set from the bar's widget settings:

| Setting | Default | |
| ------- | ------- | - |
| Show GPU and VRAM | on | Turn off to shorten the widget |
| Urgent threshold (%) | 75 | Reading turns urgent from here, halfway colour 25 points below |
| Refresh (seconds) | 2 | CPU and RAM tick; the GPU polls at half that rate |

## License

MIT
