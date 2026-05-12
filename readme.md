# albuswin
a windows optimization script.

**note**: my main os is [omarchy](https://github.com/basecamp/omarchy).
this exists because i switch to windows to play cs2 and i want the
os to stay out of the way. it runs once, reboots, done.

discuss & contribute: [discord](https://www.discord.com/invite/a4A3hhZReW) - main hub for this and likely future projects (maybe [2singals](https://www.github.com/2signals)) ty.

## usage
**playbook** — run elevated:
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex
```

**install media** — ventoy usb with autounattend, bypasses tpm/oobe:
```powershell
irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/usb.ps1 | iex
```

## what it does
runs as `TrustedInstaller`. ~3000 lines of powershell. one pass, then reboot.

- **software** — installs brave, 7-zip, vc++ redistributables, directx
- **gpu** — strips driver package to essentials, silent install. nvidia: profile inspector preset applied
- **registry** — ~400 keys across scheduling, mitigations, telemetry, input, ui
- **security** — disables vbs/hvci, spectre/meltdown mitigations, dep/aslr/cfg system-wide
- **scheduler** — `Win32PrioritySeparation=38`, 1:1 mouse curve, zero acceleration, zero animations
- **services** — disables 30+ services (telemetry, print, remote desktop, sync, sysmain, ...)
- **tasks** — disables 16 scheduled task groups (ceip, defrag, diagnostics, feedback, ...)
- **network** — nagle off, interrupt moderation off, auto-tuning restricted, nic power saving off, dscp 46
- **power** — custom plan: 100% min cpu, core parking off, heterogeneous scheduling off, all sleep off
- **hardware** — msi mode on all pci, device power management off, exploit mitigations off
- **filesystem** — 8.3 names off, last access off, platform clock removed, memory compression off
- [**albusx**](service.md) — compiles and deploys native service (0.5ms timer, irq isolation, audio buffer min)
- **debloat** — removes uwp, edge, onedrive, capabilities, telemetry binaries, 50+ dism packages
- **cleanup** — clears all startup entries, temp directories, reboots

## reversion
no rollback. reinstall windows using the usb creator.
