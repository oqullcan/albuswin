# albusx

c# service compiled at runtime via `csc.exe`, runs as `LocalSystem`.
all tuning is derived from hardware topology — no configuration needed.

---

## what it does

```
OnStart
├── detect cpu topology (p-cores vs e-cores)
├── set process to RealTime, pin to p-cores
├── allocate 4MB large pages on optimal numa node
├── disable cpu c-states
├── request 0.5ms timer resolution (NtSetTimerResolution)
├── route gpu irq → p-cores, nic irq → core 1
├── set audio buffers to hardware minimum (IAudioClient3)
├── apply udp qos dscp 46
└── start background threads:
    ├── guard     (8s)   timer drift correction
    ├── purge     (4m)   standby list eviction if ram < 1gb
    ├── watchdog  (8s)   restore priority/affinity if stolen
    └── health    (10m)  jitter analysis, auto-rearm if degraded
```

---

## irq isolation

```
nic → physical core 1 (dedicated)
gpu → physical core 2+ (all p-cores except core 0)
app → remaining p-cores
```

applied via registry + `SetupDiCallClassInstaller` device restart.
virtual adapters are excluded. original masks restored on service stop.

---

## process watchdog (optional)

place `AlbusX.exe.ini` next to the binary:
```ini
[target]
process=cs2.exe
```

uses etw kernel trace (or wmi fallback) to detect process start.
on detection: timer → 0.5ms, priority boost, p-core affinity,
ecoqos disabled, dwm → high, standby purge. all reversed on exit.

---

## key apis

| api | purpose |
|:--|:--|
| `NtSetTimerResolution` | 0.5ms timer granularity |
| `D3DKMTSetProcessSchedulingPriority` | gpu scheduler priority |
| `GetSystemCpuSetInformation` | cpu topology enumeration |
| `VirtualAllocExNuma` | numa-local large page allocation |
| `IAudioClient3` | minimum audio buffer |
| `SetupDiCallClassInstaller` | live device restart for irq |
| `CallNtPowerInformation` | disable idle states |

---
