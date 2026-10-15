# Steam Deck OLED: EC fan self-check fails after S3 resume on a 15 V / 45 W charger when charging is inhibited by the charge limit; fan output latched at 0 % until the next short suspend

Follow-up to [ValveSoftware/SteamOS#2475](https://github.com/ValveSoftware/SteamOS/issues/2475). I am the author of the 2026-10-12 comment in that thread (recipe: plugged in, never charging, ~2 min sleep). This report adds an instrumented reproduction with a sharp sleep-length threshold, 200 ms EC traces of the failing and passing resume paths, EC memory dumps in both states, a dependence on the USB-PD contract (12 V / 20 W sources pass), and confirmation that nothing on the OS side can recover the fan in this variant.

A Steam system report was sent from the device **while the fault was active** on 2026-10-14 at about 20:45 EDT (fan 0 RPM, fan1_fault=1, game closed, APU 43 °C). SteamID available to Valve on request.

## Device

| Item | Value |
|---|---|
| Model | Steam Deck OLED (Galileo), board_id 5, 1 TB |
| BIOS | F7G0114 (also present on F7G0112-era firmware per the original report on SteamOS 3.7.25) |
| EC firmware string (VERN) | G01100 |
| PD controller firmware (PDFV) | 0x1100 |
| SteamOS | 3.8.28, build 20260922.1, stable |
| Kernel | 6.18.50-valve2-1-neptune |
| Fan setting | Default (EC curve; jupiter-fan-control.service disabled) |
| Charge limit | 72 % (tests also at 60 % and 100 %) |
| Charger | 45 W, PD contract 15 V / 3 A |
| Mods | none; passwordless sudo and a root sleep hook (`scripts/deck/`) were added for this investigation only |

## Summary

1. **Deterministic recipe.** Plugged in, battery above the charge limit (status "Not charging"), suspend for **44 s or longer**, wake: fan stays at 0 RPM, `fan1_fault=1`. On the 45 W charger: 17 fails / 3 passes at 44 s to 161 s, and 14 of 14 fails since 20:20 (the 3 passes are tests 7 to 9, likely post-replug charge current; see below). Suspends of **41 s or shorter** pass (7 of 7), the same 59 to 124 s suspends **while charging** pass (2 of 2), and **unplugged** passes (130 s and 96 min).
2. **The EC runs a fan check during resume and fails it.** At 200 ms resolution the failing wake shows the EC restoring its pre-sleep fan output (54 % in one run), counting a 30-sample window with the tach at 0 RPM, then at sample 30 gating output to 0 % and clearing its fan-OK bit. On a passing wake the same counters show the check already complete (0 misses) before the kernel finishes resuming, with the fan at ~2850 RPM.
3. **Nothing from the host recovers it.** `FANS(7300)` lands in EC memory (FSLO/FSHI read back 0x1C84) and output stays 0 %. Restarting jupiter-fan-control, writing fan1_target as root, and a 2 min re-suspend from the faulted state all leave it faulted. Only a **short** suspend (9 to 15 s) clears it.
4. **OS and ACPI are clean.** No kernel/ACPI/EC errors at any resume. Steam issues no fan-mode command or privileged sysfs write within 90 s of any resume. The DSDT has no fan reset, and the EC raises no query on fan fault, so SteamOS cannot even detect it except by polling.
5. The EC's fan-loop configuration bytes are identical in faulted and healthy dumps. Only runtime fan state differs.
6. **Session-independent.** In Desktop Mode (Plasma session, no game running) the same recipe fails at 49 s and 91 s and passes at 38 s, with the identical hook signature. Gamescope and the Steam client are not involved. It also reproduces on the first suspend after a full reboot (52 s, fail; all earlier tests were on a single boot from 2026-10-12) and after a full poweroff of ~24 s with AC still connected (51 s, fail). Powering on from off in the plugged / not-charging state does not trigger it (fan 2483 RPM, fault 0 at +9 s uptime), so the cold-boot variant reported in this thread did not reproduce here. A ~62 s poweroff **with AC disconnected**, then boot and replug, does not clear it either: a 51 s suspend about 25 s after replug passed, but battery current_now was still +691 mA at entry despite the "Not charging" status; the next 52 s suspend with current_now = 0 failed with the usual signature. Post-replug charge current may also account for tests 7 to 9.
7. **Depends on the PD contract.** On a USB-C battery pack negotiating **12 V / 1.67 A (20 W)** (EC PDVL/PDAM, 0xFE700C56 to 0xC59), with the same charge-inhibited state (0x38C/0x38D = 01 / C0, current_now 0, "Not charging"), 52 s and 92 s suspends both **passed**. No AC change across either suspend (vpower "Connected at 20.04 W" after each resume; PD bytes unchanged in the pre/post hook dumps; battery % flat across the 92 s suspend). Switching back to the 45 W charger (**15 V / 3 A**) minutes later, a 52 s suspend **failed** with the usual signature. Same boot, battery level and charger state; only the PD source changed. A second 12 V / 20 W source (a wall charger, which should not cut output at low load the way some battery packs do) also **passed** a 52 s suspend, so 12 V / 20 W is 3 of 3 across two sources.
8. **Does not reproduce on a second OLED unit.** A second Steam Deck OLED (512 GB) with byte-identical firmware (SteamOS build, BIOS F7G0114, EC G01100, PDFV 0x1100, SMU/VBIOS/DMCUB) on the **same 45 W charger** (PD 15 V / 3 A), "Not charging" with current_now = 0, passed 5 of 5 suspends (50 to 121 s; battery 45 to 63 %; Desktop and Game Mode; jupiter-fan-control running and stopped). The only firmware-visible hardware difference is the battery pack: this unit's is **F7G-T0A** (model_name "ATC"), the second unit's is **F7G-M0A** ("VDL-M"). See [Second unit](#second-unit-same-firmware-same-charger-does-not-reproduce) and [`data/second-deck/`](data/second-deck/).

## Reproduction matrix (2026-10-14, all S3 "deep", times from the Deck journal)

Fixed unless stated: 45 W charger, battery 77 to 80 %, SteamOS 3.8.28, Default fan curve.

| # | Sleep | Charger / battery | Limit | Game at entry | Min since plug-in | Fan at entry | Result |
|---|---|---|---|---|---|---|---|
| 1 | 91 s | plugged / not charging | 72 | running | 42 | 4934 RPM, 70 °C | **FAIL** |
| 2 | 5 s | plugged / not charging | 72 | running | 63 | 0 (faulted) | pass |
| 3 | 131 s | plugged / not charging | 72 | running | 66 | 6087 RPM, 81 °C | **FAIL** |
| 4 | 4 s | plugged / not charging | 72 | running | 72 | 0 (faulted) | pass |
| 5 | 124 s | plugged / **charging** | 100 | running | 74 | 5804 RPM, 79 °C | pass |
| 6 | 130 s | **unplugged** / discharging | 72 | running | n/a | 4832 RPM | pass |
| 7 | 138 s | plugged / not charging | 60 | closed | 1 | 5482 RPM, 74 °C | pass |
| 8 | 127 s | plugged / not charging | 60 | running | 7 | not captured | pass |
| 9 | 82 s | plugged / not charging | 60 | running | 12 | not captured | pass |
| 10 | 161 s | plugged / not charging | 72 | running | 17 | 5434 RPM, 75 °C | **FAIL** |
| 11 | 12 s | plugged / not charging | 72 | running | 20 | 0 (faulted) | pass |
| 12 | 139 s | plugged / not charging | 60 | running | 22 | 4934 RPM, 76 °C | **FAIL** |
| 13 | 15 s | plugged / not charging | 60 | running | 26 | 0 (faulted) | pass |
| 14 | 126 s | plugged / not charging | 72 | closed | 0.15 (9 s) | 3964 RPM, 47 °C | **FAIL** |
| 15 | 122 s | plugged / not charging, **from faulted state** | 72 | closed | 6 | 0 (faulted) | **still FAIL** |
| 16 | 9 s | plugged / not charging | 72 | closed | 9 | 0 (faulted) | pass |
| sweep | 46 s | plugged / not charging | 72 | closed | 10 | ~2880 RPM, 41 °C | **FAIL** |
| sweep | 26 s | same | 72 | closed | | ~2850 | pass |
| sweep | 35 s | same | 72 | closed | | ~2900 | pass |
| sweep | 41 s | same | 72 | closed | | ~2875 | pass |
| sweep | 45 s | same | 72 | closed | | ~2875 | **FAIL** |
| sweep | 44 s | same | 72 | closed | | ~2884 | **FAIL** |
| control | 59 s | plugged / **charging** | 100 | closed | | 2884 | pass |
| desktop | 91 s | plugged / not charging, **Desktop Mode** | 72 | n/a | | 2757 RPM, 42 °C | **FAIL** |
| desktop | 49 s | same | 72 | n/a | | 2862 RPM, 39 °C | **FAIL** |
| desktop | 38 s | same | 72 | n/a | | 2884 RPM, 39 °C | pass |
| after reboot | 52 s | plugged / not charging, first suspend after full reboot | 72 | closed | | 2849 RPM, 44 °C | **FAIL** |
| after poweroff | 51 s | plugged / not charging, first suspend after ~24 s poweroff (AC connected) | 72 | closed | | 3524 RPM, 46 °C | **FAIL** |
| after unplugged poweroff | 51 s | plugged ~25 s earlier; status "Not charging" but **+691 mA** | 72 | closed | 0.4 | 2806 RPM, 42 °C | pass |
| after unplugged poweroff | 52 s | plugged / not charging, 0 mA | 72 | closed | 1.7 | 2862 RPM, 40 °C | **FAIL** |
| 20 W pack | 52 s | **12 V / 1.67 A** PD battery pack, not charging, 0 mA | 72 | closed | 1.0 | 2849 RPM, 38 °C | pass |
| 20 W pack | 92 s | same | 72 | closed | 2.1 | 2897 RPM, 38 °C | pass |
| 45 W control | 52 s | back on 45 W charger (15 V / 3 A), not charging, 0 mA | 72 | closed | 0.1 | 2862 RPM, 38 °C | **FAIL** |
| 20 W wall | 52 s | **12 V / 1.67 A** PD wall charger, not charging, 0 mA | 72 | closed | 0.7 | 2862 RPM, 38 °C | pass |

Earlier the same day, uninstrumented: 96 min on battery (16:56 to 18:32), fan working afterwards.

Tests 7 to 9 are the only long not-charging sleeps that passed; they were consecutive and followed an unplug/replug, but test 14 (9 s after replug) and test 12 (same 60 % limit) failed, so neither the limit value nor time since plug-in explains them. Game state, APU temperature and fan speed at entry do not separate the groups either. With the sweep and the later Desktop Mode, reboot, poweroff and control runs included, the not-charging long-sleep record on the 45 W charger is 17 fail / 3 pass, and 14 of 14 fail since 20:20 (excluding one run taken while current_now was still +691 mA after a replug, which passed).

## Second unit: same firmware, same charger, does not reproduce

Tested 2026-10-14 23:05 to 23:32 on a second Steam Deck OLED (512 GB). No sleep hook was installed on it; results are from fan1_input / fan1_fault read about 7 s after resume and sampled for up to a minute afterwards. Charge inhibit was produced by writing `max_battery_charge_level` below the current level (40 %, then 50 %), and each run waited for current_now = 0.

| # | Sleep | Battery | Mode | jupiter-fan-control | APU at entry | Result |
|---|---|---|---|---|---|---|
| 1 | 52 s | 45 % | Desktop | running | 42 °C | pass (2087 RPM) |
| 2 | 52 s | 45 % | Desktop | stopped (EC curve, as on this unit) | 40 °C | pass (2840 RPM) |
| 3 | 121 s | 45 % | Desktop | stopped | 39 °C | pass (2806 RPM) |
| 4 | 52 s | 57 % (8.09 V) | Desktop | stopped | 42 °C | pass (idle stop ~20 s, then 2850 RPM; fault 0) |
| 5 | 50 s | 63 % (8.24 V) | Game | stopped | 43 °C | pass (2849 RPM) |

On this unit the same charger and state fail at 38 to 46 °C, so APU temperature does not separate the two. Not tested on the second unit: battery at this unit's level (77 to 80 %, ~8.3 V).

| | This unit (1 TB) | Second unit (512 GB) |
|---|---|---|
| SteamOS / kernel / BIOS | 3.8.28 build 20260922.1 / 6.18.50-valve2-1 / F7G0114 | same |
| EC VERN / PDFV / board_id | G01100 / 0x1100 / 5 | same |
| VBIOS / SMU / DMCUB / microcode | 113-AMDSphJupiter-002 / 63.17.0 / 0x0300000a / 0x8901007 | same |
| EC fan-loop parameters (0xB90 to 0xB98) | `00 00 00 00 50 00 00 64 03` | same |
| Battery pack (EC 0xA40, BTMN 0xA60) | **F7G-T0A**, "ATC" | **F7G-M0A**, "VDL-M" |
| Battery data blocks (EC 0xA20, 0xAA0) | `01 00 0f 00 00 00 64 5c 31 00 54 30 41`, `00 04 12 31 41 41` | `00 00 05 00 00 00 21 20 31 00 4d 30 41`, `00 07 10 1f 44 31 31 30 44` |
| Battery design / full capacity | 6490 / 6722 mAh | 6470 / 6894 mAh |
| RAM / SSD | SK hynix LPDDR5 / Phison 1 TB | Samsung LPDDR5 / Kingston 512 GB |
| Steam client | 1791918634 | 1788652215 |

The fan itself, its connector, and other passive parts are not visible from software. Since several independent users report the same symptom, a part variant interacting with EC logic (battery pack being the leading candidate, given that the failure is confined to the charge-inhibited AC state) seems more likely than a one-off defect, but this is not established.

## What the EC does at resume (200 ms traces from a root systemd sleep hook; t = 0 is the hook start, about 0.1 s after the kernel's "PM: suspend exit")

Failing wake, test 14 (126 s, not charging, fan 3964 RPM / 54 % output before sleep):

```
t(ms) fan_in fault | out(0x32E) 0x39F  RPM  | 0x403 0x404 0x405 | AC 0x38D
   20     0    1   |   0x36=54%  0x08   0   |  09    15    00   | 01 c0
  241     0    1   |   0x36      0x08   0   |  06    18    00   |
  462     0    1   |   0x36      0x08   0   |  04    1a    00   |
  683     0    1   |   0x36      0x08   0   |  02    1c    00   |
  905     0    1   |   0x36      0x08   0   |  00    1e    00   |
 1126     0    1   |   0x00= 0%  0x02   0   |  00    1e    00   |   <- latched; unchanged for the rest of the 5 s and for minutes after
```

Failing wake, test 15 (re-suspended 122 s from the faulted state): identical counter sequence, output 0x00 throughout (its pre-sleep value), latched again.

Passing wake, test 16 (9 s): at t = 22 ms fan 2832 RPM, output 0x26 = 38 %, 0x39F = 0x03, counters 1C 00 02; steady afterwards. All passing wakes look like this.

Reading: 0x403 + 0x404 = 30 in every sample. 0x404 counts tach-miss samples up to 30 while 0x403 counts remaining tries down; healthy wakes finish at 28 remaining / 0 or 1 misses. The EC's output level (0x32E, tracks RPM/7300 to 1 % in every healthy dump; here it is held at the pre-sleep value with 0 RPM, so it is the commanded level, not a measurement) is non-zero during the window and the fan does not turn. After 30 misses the EC drives 0 % and clears bit 0 of 0x39F (FNCK, read by ACPI `FANC`, inverted by the driver into fan1_fault). The window started well before the host resumed (21 of 30 samples were already consumed at t = 0, about 4.5 s at the observed 0.22 s cadence).

## Everything tried from the host while faulted (all left fan at 0 RPM, fault 1)

| Action | Observation |
|---|---|
| `jupiter-fan-control --enable` (fancontrol.py commanded 2000 then 7300 RPM, logged "Setting fan to max speed") | output byte stays 0 |
| `--disable` (FANS(0)) then `--enable` again | same |
| Root write of fan1_target = 7300 with the service stopped, then read the EC set-point bytes directly | **FSLO/FSHI (0xFE700B92/93) = 0x1C84: the command landed**; output 0, FNCK 0 |
| Root writes 0, 7300, 0, 1000, 7300 | same |
| Rebind of the steamdeck-hwmon platform driver | null test (MFD child; no EC interaction) |
| 2 min suspend from the faulted state | still faulted (test 15) |
| 9 to 15 s suspend | **recovers every time** (tests 2, 4, 11, 13, 16, and all sweep recoveries) |

The resume-time `systemctl restart jupiter-fan-control` workaround from this thread therefore cannot help this variant: the service runs and commands max speed, and the EC does not drive the fan.

## Firmware-level picture

- ACPI fan surface (DSDT): `FANS(n)` writes FSLO/FSHI and command 0xCC (or 0xCD for n = 0 / auto) to I/O port 0x6C; `FANR` reads FNRL/FNRH; `FANC` returns FNCK (EC RAM 0x9F bit 0, via the 0xFE700300 mirror). No fan reset or recalibrate exists. No EC `_Qxx` handler is fan related, so the EC never notifies the OS of FNCK = 0. `_PTS`/`_WAK` touch nothing fan related.
- EC fan-loop parameters at 0xFE700B90 to 0xB98 (CRLO/CRHI, FSLO/FSHI, CPUT, GNLO/GNHI, FRPR, HYST) are byte-for-byte identical in faulted and healthy dumps. MCBL (0xFE700B9F) tracks the charge limit (0x48 / 0x3C / 0x64), confirming that page is live.
- Charger bytes during failing windows: 0x38C bit 0 = 1 (AC present), 0x38D = 0xC0 (charge inhibited; 0x80 while charging), MCUR = 0 mA. PD contract bytes identical in all dumps (15 V / 3 A / 45 W).
- Named but unreferenced EC fields that may be relevant and that I did not write: FNOV (EC RAM 0x42 bit 6), SFAN (0xF4), S3 flag bits at 0xF8.
- Chip identification per iFixit: charger MPS MP2762A, EC likely ITE IT81302. The LCD model uses different charger/PD parts; if an LCD unit shows this, the mechanism is EC branch logic rather than a charger-IC timer.

## Interpretation (hedged)

On resume from S3 the EC restores its previous fan output and runs a 30-sample tach check. When the suspend lasted about 43 s or more **and** AC is present with charging inhibited, the fan does not turn under drive during that window, so the check fails, output is gated to 0 % and FNCK is cleared; the state persists through further long suspends and through every host command, and is cleared only by a suspend short enough that the EC apparently never enters the state that arms the problem. Why the fan does not turn under drive on that path is not observable from the host: candidates are the fan rail or driver enable not being restored on the AC-idle resume branch, or the check running before the rail is good. The sharp 41 to 44 s edge suggests a fixed EC-side timer after S3 entry (an EC low-power idle transition or a ~40 s charger-supervision/watchdog class event that only matters when the charger is idle). The cold-boot variant reported above by another user in the same charger state fits the same check failing at power-on, although it did not reproduce on this unit. Because a 12 V / 20 W source avoids the failure while 15 V / 45 W triggers it in the same charge-inhibited state, the failing branch depends on the PD contract (input voltage, power level, or the charger IC's operating mode at that input), not on charge inhibit alone. A second OLED unit with identical firmware does not fail on the same charger in the same state (5 of 5), so the failing path also depends on something unit-specific. The battery pack variant (F7G-T0A vs F7G-M0A) is the only difference visible to firmware and sits on the same charger/gauge path; the fan and other passive parts cannot be compared from software.

## Requests

1. Fix the failing resume branch, and independently make the fan check fail safe: on tach loss drive full duty open-loop and re-check periodically, instead of latching 0 % until the next S3. That alone makes this harmless whatever the root cause.
2. Expose a fan re-init path through ACPI/hwmon, and/or raise an EC query on FNCK = 0 so SteamOS can react (today the only remedy is a short re-suspend).
3. Are FNOV / SFAN a live override path on G01100? Is there an EC changelog covering fan init across S3?
4. Does the EC treat the F7G-T0A and F7G-M0A battery packs differently in the charge-inhibited state? Affected users could report `cat /sys/class/power_supply/BAT1/model_name` to check whether the failure tracks the pack variant.

## Workarounds until fixed

After any suspend longer than ~40 s while docked or plugged with the battery at its charge limit, do a short suspend/resume before gaming. Raising the limit so the battery charges during sleep works only until the battery reaches the new limit. A 12 V / 20 W PD source avoided it in 3 of 3 tests (two different sources).

## Method notes

Measurements over SSH (deck user; root via sudo for /dev/mem reads, read-only ec_sys, and fan1_target writes through the official hwmon interface). No EC registers were written. Post-resume traces come from a systemd unit bound to sleep.target (`ExecStart` at suspend entry, `ExecStop` at resume) sampling the EC window at 200 ms for 5 s on the Deck's own clock. PD contract values were read from EC PDVL/PDAM (0xFE700C56 to 0xC59). Hook, sudo rule and loggers were added for this investigation only.

## Attachments

- [`LOG.md`](LOG.md): full timestamped working log.
- [`data/sleep-hook/sleephook-full.log`](data/sleep-hook/sleephook-full.log): pre-suspend and post-resume snapshots with 200 ms samples for every suspend from 20:31 onward, including the sweep, the charging control, Desktop Mode, reboot, poweroff and charger tests.
- [`data/wake-captures/`](data/wake-captures/): per-test captures from the PC-side watcher (1 s samples after reconnect), e.g. `long-plugged-capture.txt` (failing wake) and `long-charging-capture.txt` (passing).
- [`data/ec-dumps/`](data/ec-dumps/): `ec-mmio-faulted-19-45.txt`, `ec-mmio-healthy-19-50.txt`, `ec-ram-faulted-19-40.hex`/`.bin`, `ec-diff-faulted-vs-healthy.txt`.
- [`data/acpi/DSDT.dsl`](data/acpi/DSDT.dsl) (FANS/FANR/FANC at lines 5345 to 5420; EC field maps at 4328 to 4890; PDVL/PDAM at 5698 to 5722) and the raw `DSDT.aml`.
- [`data/soak/soak.log`](data/soak/soak.log): 5-minute idle soak samples on AC.
- [`data/second-deck/`](data/second-deck/): second unit's test results, firmware and hardware inventory, and battery EC fields for both units.
- [`scripts/deck/`](scripts/deck/): `90-fanprobe.sh` + `fanprobe-sleep.service` (sleep hook), `ecfast.py` (200 ms EC sampler), `ecmmio.py` (EC window dump), `wakecap.sh`, `soaklog.sh`.
- [`scripts/pc/`](scripts/pc/): `cycle.ps1` (one cued suspend/resume cycle with result capture), `wake-watch*.ps1` (reconnect watchers), `ecdiff.py`.
