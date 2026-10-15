> Raw working log, kept as written during the investigation. File paths refer to the original working folder: `captures/sleephook*.log` is now `data/sleep-hook/sleephook-full.log`, other `captures/*-capture.txt` files are in `data/wake-captures/`, EC dumps are in `data/ec-dumps/`, DSDT is in `data/acpi/`, and Deck-side scripts are in `scripts/deck/`.

# Steam Deck OLED fan-after-sleep troubleshooting log

Device: Steam Deck OLED (Galileo), BIOS F7G0114, SteamOS 3.8.28 (build 20260922.1), kernel 6.18.50-valve2-1-neptune
Access: SSH from Windows PC as user `deck` (no root; `deck` sudo requires password)
All times are Deck local time (EDT) on 2026-10-14 unless noted.

## Baseline (fan working, game Sifu running)

- 19:24:59  Fan 3517 RPM, APU 54 C, GPU idle (menu/loading moment). fan1_fault=0, fan1_target=0 (EC control).
- 19:25:xx  Five 1 s samples: fan 4050-4080 RPM, APU 66-67 C, GPU 17-99 %, sclk up to 1.59 GHz, ~11 W of 15 W cap.
- 19:26:47  Fan 4934 RPM, APU 70 C, fan1_fault=0.
- Fan control mode: `jupiter-fan-control.service` disabled/inactive (Steam "Default" fan curve = EC controls fan). Steam re-issued `jupiter-fan-control --disable` at 19:24:12 (normal on game launch / settings apply).
- Earlier suspend today 16:56:29 -> resume 18:32:48 with the same game open: fan came back working (per user).
- hwmon map: hwmon3 = steamdeck_hwmon (fan1_input, fan1_fault, fan1_target), hwmon6 = amdgpu (edge temp), hwmon1 = acpitz.

## Sleep test 1

- 19:27:18  System suspended (S3, "deep"). AC connected at 45 W, battery 77 %.
- 19:28:49  Resume. Kernel log clean: EC stopped/started, SMU resumed, no errors.
- 19:29:01  First SSH read, 12 s after resume: **fan 0 RPM, fan1_fault=1, target 0, APU 66 C, GPU 100 %**. Fan never restarted.
- 19:30:08  fan 0, fault 1, APU 100 C, acpitz 100 C, GPU 99 %. Game still running.
- 19:31:09  APU 83 C, GPU 100 %.  19:32:00  APU 77 C, sclk pinned at 200 MHz (thermal throttling).

## Attempts to restart the fan from software (all as user deck, no root)

| # | Time | Action | Result |
|---|------|--------|--------|
| 1 | 19:30:37 | `steamos-polkit-helpers/jupiter-fan-control --enable` (start OS fan control; fancontrol.py writes fan1_target) | Service active. Target 2000 then 7300 (max, "temp > 90, setting fan to max"). Fan stays 0 RPM, fault=1. |
| 2 | 19:33:59 | `jupiter-fan-control --disable` (return to EC control, target 0), wait 5 s, `--enable` again | EC mode: fan 0, fault 1, target 0. After re-enable: target 2000 -> 4282. Fan stays 0 RPM, fault=1. |

## Observations

- Writing any fan1_target value (0, 2000, 4282, 7300) has no effect while fan1_fault=1. The EC is not driving the fan at all.
- Kernel/ACPI/EC logs show nothing abnormal at resume. The fault is internal to the EC fan controller or fan hardware.
- Latest OLED BIOS (F7G0114 = "v114" shipped with SteamOS 3.8) already installed; no newer firmware found.
- Community reports of the same symptom (fan 0 RPM after sleep, recovers after another sleep or power cycle): https://github.com/ValveSoftware/SteamOS/issues/1531 , https://steamcommunity.com/app/1675200/discussions/0/3273566073563016624/
- Root-free write paths available: `steamos-priv-write` allowlist does NOT include fan1_target or anything fan related (only backlight, dpm level, pp_od_clk_voltage, power*_cap, ALS, LEDs).
- fancontrol.py references a sysfs attribute named `recalculate` next to fan1_target (lines 142/155) - investigating.

## Investigation of remaining software knobs (19:34-19:36)

- `steamos-priv-write` (root-less sysfs writer used by Steam) allowlist: backlight, dpm perf level, pp_od_clk_voltage, hwmon power*_cap, ALS integration time, LEDs. **No fan path.** Dead end.
- fancontrol.py `gain` / `ramp_rate` / `recalculate` attributes are only used on pre-"std" BIOS (F7G < 7). On F7G0114 the script's only fan interface is `fan1_target`, which we already drove. Dead end.
- steamdeck_hwmon sysfs exposes only: fan1_input, fan1_fault, fan1_target (root-writable), battery charge limits. No fan reset/recalibrate attribute on this BIOS.
- VLV0100 EC: board_id=5, firmware_version=4352 (0x1100). controller_board_power not readable as deck.
- Conclusion: from an unprivileged shell, every available software path to the fan has been tried. The EC rejects/ignores all targets while fan1_fault=1.
- 19:35:52  fan 0, fault 1, target 4100, APU 81 C, game still running (GPU throttled to 200 MHz).

### Possible with root (not yet attempted, needs deck password or NOPASSWD sudo)
- Unbind/rebind the `steamdeck-hwmon` platform driver (re-probes the ACPI device).
- Read EC RAM via `/sys/kernel/debug/ec/ec0/io` (read-only inspection of fan registers; no writes - register map undocumented).
- Reload `steamdeck_hwmon` kernel module.

## Root attempts (19:37-19:39)

- 19:37:16  User created /etc/sudoers.d/99-deck-nopasswd (`deck ALL=(ALL) NOPASSWD: ALL`).
- 19:38:0x  Attempted as root: load ec_sys + read EC RAM, stop fan service, direct fan1_target writes (0/7300/0/1000/7300). **All sudo calls still required a password** - root attempts not actually executed.
- Cause: sudoers.d files parse in lexical order and the last matching rule wins. `99-deck-nopasswd` sorts before `wheel` (`%wheel ALL=(ALL) ALL`), so the wheel rule re-imposes the password. Fix: rename to a name sorting after `wheel` (e.g. `zz-deck-nopasswd`) and chmod 0440.
- Fan status during this window: 0 RPM, fault 1, APU 84 C, fan service still active and cycling targets 4754-4929.

## Root attempts, take 2 (19:39-19:41) - sudoers fixed (zz-deck-nopasswd, 0440)

| # | Time | Action | Result |
|---|------|--------|--------|
| 3 | 19:39:5x | Load `ec_sys` (read-only) and dump EC RAM (256 B) in the faulted state. Saved to captures/ec-ram-faulted-19-40.{bin,hex}. EC version string "G01100" visible at offset 0xFA. | Snapshot only; for comparison against a healthy dump later. |
| 4 | 19:40:05-19 | Stop jupiter-fan-control, write fan1_target directly as root: 0, 7300, 0, 1000, 7300 (3 s apart). | Target readback follows each write. **Fan stays 0 RPM, fault=1 throughout.** |
| 5 | 19:40:45 | Unbind then rebind the `steamdeck-hwmon` platform driver (re-probe of ACPI device VLV0100). | Rebind succeeded, hwmon3 recreated. Fan 0, fault 1. Writing 7300 afterwards: still 0 RPM, fault 1. No kernel messages. |

- Also saved the ACPI DSDT (captures/DSDT.aml, 34566 B) for later decompilation to map FANS/FANR/FAN-fault methods to EC registers.
- Left fan in EC control (target 0), fan service stopped, as in the user's normal "Default" configuration.

## ACPI table analysis (19:42-19:44) - DSDT decompiled with iasl in WSL (captures/DSDT.dsl)

- Fan control path: `FANS(target)` (called by steamdeck-hwmon fan1_target write) sets FSHI/FSLO bytes in the EC MMIO window (0xFE700Bxx) then writes a command byte to **I/O port 0x6C**: `0xCC` = run at the given RPM (clamped to 0x1C84 = 7300), `0xCD` = target 0, return to EC automatic control.
- Fan RPM readback: `FANR` = FNRH:FNRL at EC MMIO 0xFE7003B0/B1.
- Fan fault: `FANC` returns non-zero when **FNCK** (bit 0 at EC MMIO 0xFE70039F) == 1. Returns 2 if CPU temp CTMP > 95 C, else 1. This is the "fan check failed" flag the EC raises itself (fan tach not detected). Nothing in the ACPI table ever clears it; only the EC firmware can.
- Other EC command-port values present: 0xCB and 0xCE (purpose being checked). No "fan reset" method exists in the ACPI table.
- EC RAM (port 0x62/0x66 "ERAM") map confirms the faulted dump: RTMP (0x58) = 0x52 = 82 C, FSPD (0x5C) = 0, RPM1/RPM2 (0xB2/B3) = 0, VERN (0xFA) = "G01100".
- Kernel has CONFIG_STRICT_DEVMEM + IO_STRICT_DEVMEM; /dev/mem and /dev/port exist (root). No acpi_call module, no acpi debugfs custom_method.
- 19:43:42  **APU 95 C**, fan 0, fault 1, game still running at 100 % GPU. Warned user to close game.
- EC command port 0x6C values: 0xCC set-RPM, 0xCD auto, 0xCB = DPCY (display cycle), 0xCE = LED mode (SLDM). **No fan-reset command exists in the ACPI table.**
- EC MMIO page 0xFE700B00 holds the EC fan loop parameters: CRLO/CRHI (0x90), FSLO/FSHI (0x92, set-point), CPUT (0x94), GNLO/GNHI (0x95, gain), FRPR (0x97, ramp rate), HYST (0x98). These are what the old fancontrol.py `gain`/`ramp_rate` attributes wrote.
- _PTS/_WAK do nothing fan-related; the EC re-initialises its own fan loop across S3 (which is why a sleep cycle normally recovers it).
- Next: read EC MMIO window 0xFE700000-0xFE700FFF read-only via /dev/mem (root) to capture FNCK and loop params in the faulted state (captures/ec-mmio-faulted-19-45.txt).

## EC memory window read (19:45, root, read-only) - captures/ec-mmio-faulted-19-45.txt

- Fan-check bit FNCK (0xFE70039F bit 0) = **0**. The steamdeck-hwmon driver inverts FANC, so fan1_fault=1 means "EC says fan check NOT OK". Healthy state should show FNCK=1. It is an EC status output, not a control; writing it would accomplish nothing.
- EC fan-loop parameters (0xFE700B90..): CRLO/CRHI=0, FSLO/FSHI=0 (auto mode), CPUT=80, gain=0, ramp=100, hysteresis=3, max RPM 0x1C84=7300 at 0xB9C and 0xBA0. All look normal/default.
- Measured RPM FNRL/FNRH = 0. CTMP = 88 C at time of read.
- Page 0x300 is a mirror of the port-0x62/0x66 EC RAM (matches ec_sys dump).
- **Conclusion of software attempts:** every OS-reachable fan interface (ACPI FANS via hwmon, direct root writes, driver rebind, mode toggles) has been exercised and the EC ignores all of them while its own fan-check has failed. No fan-reset path exists in firmware's ACPI interface. Recovery requires the EC to re-run its fan init, which happens on S3 resume (per user experience) or a power cycle.
- 19:45:00  APU 86 C, fan 0, fault 1, game still running.

## Planned: recovery capture
- Push /home/deck/wakecap.sh; PC-side watcher retries every 2 s and runs it on first connection: immediate fan state, EC MMIO snapshot, 45 x 1 s samples, EC dumps, journal. Output: captures/wake2-capture.txt. Healthy EC dumps will be diffed against the faulted ones.

## Sleep test 2 - quick cycle (user-initiated), plugged in

- 19:48:29  suspend entry.  19:48:34  suspend exit (about 5 s asleep).
- 19:48:55  **fan 6087 RPM, fan1_fault=0**, APU 85 C, target 0 (EC auto). Fan recovered, as the user predicted for a short sleep.
- Watcher failure (my error): the watcher was launched under Windows PowerShell 5.1, whose Test-Connection lacks -TimeoutSeconds, so the "wait for Deck to go down" phase exited immediately and the capture script ran BEFORE the sleep. No sub-second post-resume data for this cycle. Fixed by running under pwsh 7 for the next test.
- Healthy EC dumps taken at 19:49 (captures/ec-mmio-healthy-19-49.txt) for diff against the faulted dumps.

## EC memory diff, faulted vs healthy (captures/ec-diff-faulted-vs-healthy.txt)

Fan-related differences (addresses in the 0xFE700000 MMIO window; page 0x300 mirrors EC RAM):
- 0x39F (FNCK byte): 0x02 faulted -> 0x03 healthy. Bit 0 = fan check OK. Matches fan1_fault.
- 0x39D: 0x01 faulted -> 0x08 healthy. Unnamed in ACPI. Looks like an EC fan state byte (1 = stalled/fault?, 8 = running).
- 0x344 (EC RAM 0x44, unnamed): 0x24 faulted -> 0x04 healthy. **Bit 5 set only while faulted.** Candidate EC "fan failure" status flag.
- 0x3B0/0x3B1 (FNRL/FNRH): 0 -> 0x1803 = 6147 RPM.
- 0x403..0x405: 00 1e 00 -> 1c 00 02 ; 0x430: c2 02 -> a7 00 ; 0x439: 00 -> 02 ; 0x819: 04 -> 00. Unnamed EC-internal state that flips with fan state.
- 0xB9C/0xBA0: 0x1C84 (7300) faulted -> 0 healthy. These held the last non-zero target I wrote; EC cleared them on re-init. Artefact of my tests, not a cause.
- Fan-loop parameters (0xB90-0xB98) identical in both states: the EC's configuration did not change; only its runtime fan state did.
- Everything else that differs is temperatures (88 C -> 83 C) and counters.

## Sleep test 3 - long sleep (131 s), plugged in (45 W), started from a healthy fan

- 19:51:18  suspend entry (fan was healthy, 6087 RPM, before sleep).
- 19:53:29  suspend exit. AC 'Connected' at 45 W, battery 77 %.
- 19:53:30  watcher SSH connected (attempt 33, ~1 s after resume); capture script running.
- 19:53:46  direct read: **fan 0 RPM, fan1_fault=1**, target 0, APU 76 C, GPU 99 %.  **Failure reproduced.**
- User's observation confirmed: short sleep (5 s) -> fan recovers; long sleep (2 min) -> fan dead on resume. Both plugged in, so charger state is not the differentiator between tests 2 and 3.
- Watcher capture (captures/long-plugged-capture.txt): first read at 19:53:30.978, **1.5 s after resume: fan 0 RPM, fault=1, APU 61 C, EC CTMP 51 C**. The EC never spun the fan up at all after this resume; it was not a later stall. 46 one-second samples, fan 0 throughout. At +45 s EC CTMP = 96 C (game Sifu relaunched by user, GPU 100 %).
- EC bytes revisited with this third dump: 0x344 = 0x04 here (0x24 in the 19:45 faulted dump, 0x04 healthy) -> bit 5 is NOT a fault flag; discard. 0x39D = 0x07 here (0x01 at 19:45 faulted, 0x08 healthy) -> varies, inconclusive. FNCK (0x39F bit 0) remains the only reliable indicator: 0 in all faulted dumps, 1 healthy.
- Working hypothesis: the trigger is the fan having physically stopped during sleep (long enough sleep), not temperature or charger. Short sleep (fan still coasting) passes the EC's wake-time fan check. Tests to confirm: (a) 30 s sleep with fan running; (b) 2 min sleep from idle with fan at minimum.

## Battery/charger state check (19:56) - user's theory: fault only when battery is NOT charging

- Charge limit (max_battery_charge_level) = 72 %. Battery = 78 %, status "Not charging", current_now = 0 uA, voltage 8.285 V. AC online, PD contract 15 V / 3 A (45 W). vpower reports status 'Full' at each plugged resume.
- So: plugged in but **battery not charging** during all three failing resumes today (19:28, 19:53, and 19:27's entry state). The one long sleep that recovered (16:56 -> 18:32) was on battery, 'Discharging'.
- Consistent with the user's theory. Also consistent with the "fan physically stopped during sleep" theory. Discriminating tests:
  (a) 2 min sleep UNPLUGGED (discharging): user's theory -> fan OK; stopped-fan theory -> fan dead.
  (b) 2 min sleep plugged with charge limit raised above battery level so it actually charges: user's theory -> fan OK.
- Fan still dead at 19:56 (fault 1, APU 81 C, game running, throttled). Watcher "quick2" armed for the next cycle.

## Sleep test 4 - quick cycle (4 s), plugged, battery not charging

- 19:57:02 suspend entry (fan dead before sleep). 19:57:06 suspend exit. Watcher connected 19:57:08 (attempt 2).
- 19:57:28  **fan 5403 RPM, fault 0**, APU 86 C, game still running. Recovered. Capture: captures/quick2-capture.txt.
- Note: this recovery happened plugged in with the battery NOT charging, so "not charging" alone does not prevent recovery on a short sleep. Watcher "long-unplugged" armed for test 5 (2 min sleep, charger disconnected).
- Quick2 capture detail: 2.7 s after resume fan already at 2884 RPM, fault 0, FNCK=1, EC CTMP 84 C. Fan ramped 2884 -> 6996 RPM over 45 s with ramp rate ~400-450 RPM/s. On a short sleep the EC fan loop is clearly alive from the first second; on a long sleep it never starts at all.

## Sleep test 5 setup - long sleep, plugged in, battery CHARGING (user's preferred discriminator)

- 19:59  Raised max_battery_charge_level 72 % -> 100 % as root. Within 6 s: BAT1 status 'Charging', current_now +508 mA, capacity 78 %. Fan healthy 5804 RPM, fault 0, APU 79 C before sleep.
- Watcher "long-charging" armed. Plan: suspend (not shutdown) ~2 min, wake, observe fan. Charge limit to be restored to 72 % afterwards.
- Prediction (user's theory): fan works on wake. Prediction (stopped-fan theory): fan dead on wake.

## Sleep test 5 result - long sleep (124 s), plugged in, battery CHARGING

- 19:59:21 suspend entry. 20:01:25 suspend exit; vpower: AC 'Connected' 45 W, battery 79.9 %, status 'Charging'.
- 20:01:28 watcher connected (attempt 32, ~3 s after resume). 20:01:37 direct read: **fan 3989 RPM, fault 0**, APU 71 C, battery Charging at +2.9 A. **Fan survived the long sleep.**
- Same sleep length and same charger as failing test 3; the only changed variable is that the battery was charging. **User's theory confirmed on this pair.**
- Interpretation note: this is consistent with two mechanisms that are not yet separated: (i) the EC's resume-time fan init misbehaves specifically in the "AC present, battery full/not charging" state; or (ii) while charging in S3 the EC keeps the fan running, so it never stops and the wake-time fan check passes. Either way the practical trigger for the user is: plugged in + battery at/above the charge limit + sleep longer than a few seconds.
- Remaining discriminator (optional): 2 min sleep unplugged (discharging). 16:56->18:32 (96 min, on battery) already recovered fine, suggesting unplugged is also safe, which points at mechanism (i).
- Charge limit restored to 72 % at 20:02.
- Test 5 capture detail (captures/long-charging-capture.txt): first read 20:01:27.641, 2.6 s after resume: **fan already 2786 RPM**, fault 0, APU 63 C. Fan held ~2786-2798 RPM for the first 3 s, then ramped at ~400-450 RPM/s to ~5400 RPM. At the EC's measured ramp rate a spin-up from 0 would need ~7 s to reach 2786, so the fan was most likely already turning when the OS resumed, i.e. the EC kept the fan running during S3 while charging. This favours mechanism (ii): the fault appears when the fan was fully stopped at wake, and charging prevents that by keeping the fan on during sleep. Compare failing test 3: 1.5 s after resume, fan 0, EC temp 51 C, no spin-up ever attempted.
- **Correction (20:04, from user observation):** the fan is NOT audible during sleep in any test, charging or not. The "fan already spinning at wake" inference above is withdrawn. Re-reading the data: both successful wakes (tests 4 and 5) show the fan jumping straight to ~2800 RPM within 2-3 s of resume (2884 and 2786 RPM), which is the EC's fan start-up floor on a fresh init, not a coasting fan. The ~400 RPM/s ramp seen afterwards is the EC's steady-state adjustment, not its start-up behaviour.
- Revised interpretation: the fan is stopped during sleep in every case. What differs is the EC's state at resume. With AC present and the battery NOT charging, after a sleep of ~90 s or more, the EC skips/fails fan init and latches fan-check = failed. With the battery charging (same charger, same sleep length) the EC inits the fan normally. Short sleeps (4-5 s) recover even when not charging, so the EC must not fully enter whatever sleep state causes the skip within the first seconds.
- Mechanism (ii) is therefore dropped. The condition is: **AC present + battery not charging + sleep longer than a few seconds.**

## Sleep test 6 setup - long sleep, UNPLUGGED (discharging)

- 20:05:17 (PC time) Deck went down; charger disconnected before sleep; fan healthy before sleep. Watcher "long-unplugged" armed.
- 20:06  User confirms audibly: fan is NOT running while asleep.

## Sleep test 6 result - long sleep (130 s), UNPLUGGED

- 20:05:16 suspend entry. 20:07:26 suspend exit; vpower: AC 'Disconnected', battery 80 %, 'Discharging'.
- 20:07:30 watcher connected (attempt 34). 20:07:40 direct read: **fan 4032 RPM, fault 0**, APU 68 C. User confirms fan audibly on. **Unplugged long sleep is safe.**
- Final matrix: the fault occurs only with AC present AND battery not charging AND sleep of ~90 s or more. Unplugged, charging, or short sleep all recover normally.
- Test 6 capture detail (captures/long-unplugged-capture.txt): first read 20:07:29.988, 3.5 s after resume: fan 3216 RPM, fault 0, APU 59 C; ramped to ~4900 RPM over 45 s. Normal EC fan init.
- Prior art found: https://github.com/ValveSoftware/SteamOS/issues/2475 "Fan fails to resume after sleep when charging at battery charge limit" (filed on SteamOS 3.7.25). Same condition as established here. Also #1531 (generic fan-stops reports).
- Issue #2475 details (fetched 20:10): opened 2026-06-15 on SteamOS 3.7.25, still open. Three independent reproductions incl. an OLED on 3.8.16 with fan1_fault=1 / target 7300 / 0 RPM / 99 C. A Valve engineer (austinp-valve, 2026-09-23) asked for a system report captured while the fault is active. Comment by "eliog" on 2026-10-12 already describes the plugged-in / never-charging / 2 min sleep recipe. Reporter's resume-time `systemctl restart jupiter-fan-control` workaround does NOT help this variant (confirmed here: EC ignores all targets).

## Sleep test 7 setup - final reproduction for the report: plugged, limit lowered to 60 %, ~2 min sleep

- 20:10  Charge limit set 72 % -> 60 % as root so the battery (80 %) is well above it. Watcher "repro-plugged-limit60" armed. Plan: plug in, confirm 'Not charging', sleep ~2 min, wake; then send a Steam system report from the Deck while faulted; then quick sleep/wake to clear; restore limit to 72 %.
- 20:10:01-20  Plugged in: AC online, PD 15 V / 3 A, limit 60 %, battery 78 %, status **'Not charging'**. Note: BAT1 current_now reads ~2.7 A (unsigned) here, unlike the 0 uA seen at 19:56; the fuel-gauge value appears to reflect system draw with the game (Sifu) still running. Status 'Not charging' is the condition under test. Fan healthy 5482 RPM, APU 74 C before sleep.
- 20:10:30  Watcher glitch: a single lost ping while the Deck was still awake tripped the "went down" check, so the first watcher connected pre-sleep. Stopped it; watcher now requires 3 consecutive failed pings. Re-armed as "repro-plugged-limit60-b" while the Deck is already asleep (ping confirmed down at 20:10:40).
- Variable noted by user: in test 7 the game was CLOSED before sleep (idle Steam UI). In tests 1 and 3 (both failed) the game was running at sleep entry. If test 7 passes, "load at sleep entry" becomes a candidate factor; if it fails, it is ruled out.

## Sleep test 7 result - long sleep (138 s), plugged, NOT charging (limit 60 %, battery 78 %), GAME CLOSED before sleep

- 20:10:57 suspend entry. 20:13:15 suspend exit; vpower: AC 'Connected' 45 W, battery 77.7 %, status 'Full'.
- 20:13:17 watcher connected (attempt 23). 20:13:27 direct read: **fan 2862 RPM, fault 0**, APU 46 C, 'Not charging'. **Fan recovered - failure NOT reproduced.**
- Difference from failing tests 1 and 3: game was closed at sleep entry (Steam UI idle, APU cooler, fan lower). Tests 5 and 6 (passes) had the game running but were charging / unplugged.
- Updated matrix: fail = plugged + not charging + game running at sleep entry (2/2). plugged + not charging + idle = pass (1/1). Either the game/load state at sleep entry is a required factor, or the fault is intermittent in this state. Next: repeat plugged + not charging with the game running (expected fail) to separate the two.
- Lead to check: with a game open, Steam re-applies per-game performance settings on resume (fan mode via jupiter-fan-control --disable/--enable = ACPI FANS(0) = EC command 0xCD, TDP via power1_cap, GPU clock via power_dpm/pp_od) through pkexec / steamos-priv-write. If an EC 0xCD/0xCC command lands during the EC's own post-S3 fan init, that could be the race. Checking the journal around each resume.
- Journal check (20:14): **Steam issued no fan-mode command and no privileged sysfs write within 90 s of any resume today.** The only jupiter-fan-control calls this boot were at 19:24:12 (game launch, --disable) and my own at 19:30-19:34. The "Steam re-applies settings at resume" lead is ruled out: the OS sends nothing to the EC's fan interface at resume. The game-running factor must act through the EC's own state at sleep entry (fan at ~5000-6000 RPM and APU ~70-80 C with a game, vs ~2800 RPM / ~50 C idle).
- Watcher "repro-plugged-game" armed for test 8: plugged, limit 60 %, not charging, game running and warm at sleep entry, ~2 min sleep. Expected: fail (replicates tests 1 and 3).

## Sleep test 8 result - long sleep (127 s), plugged, NOT charging (limit 60 %, battery 78 %), GAME RUNNING

- 20:16:09 suspend entry (game Sifu running). 20:18:16 suspend exit; vpower: AC 'Connected' 45 W, battery 77.7 %, 'Full'.
- 20:18:18 watcher connected (attempt 31). 20:18:29 direct read: **fan 3000 RPM, fault 0**, APU 65 C, GPU 99 %, 'Not charging', limit 60 %. **Fan recovered - failure NOT reproduced**, despite matching the recipe of failing tests 1 and 3 (plugged, not charging, game running, ~2 min).
- So "game running" is not sufficient either. Comparing the two failures with the two passes in this power state:
  - Tests 1 and 3 (FAIL): charger had been connected continuously since 18:45 (43 min and 66 min of AC-present-not-charging before sleep). Limit 72 %, battery 77 %.
  - Tests 7 and 8 (PASS): charger re-connected at 20:09 after test 6 (only 1-7 min of AC-present-not-charging before sleep). Limit 60 %, battery 78 %.
- New candidate factor: **time spent in the AC-present / battery-idle state before sleeping** (EC charger state machine settling into some idle mode), rather than the instantaneous status. Consistent with upstream #2475 reports (left in suspend overnight; docked for long periods). Alternative: the fault is simply intermittent in this state (upstream reporter also says "intermittent").
- Next: leave plugged in and not charging (limit 60 %) for 30+ min, then repeat the 2 min sleep with the game running.
- Test 8 capture detail (captures/repro-plugged-game-capture.txt): first read 20:18:18.468, 2.5 s after resume: fan 2862 RPM, fault 0, APU 55 C; ramped to ~4900 RPM. Normal EC fan init.
- 20:20  Report draft written: H:\steamdeck\valve-report-draft.md (follow-up for issue #2475). Mis-timed captures (quick-capture, wake2-capture, repro-plugged-limit60-capture) moved to captures/discarded.
- Test 9 plan: soak plugged + limit 60 % + not charging for 30+ min while gaming, then ~2 min in-game sleep.

## Sleep test 9 - plugged, limit 60 %, not charging, game presumably running; soak shorter than planned

- ~20:22  User put the Deck to sleep (already down when checked at 20:22). Charger continuously connected since 20:09 (~13 min on AC, battery idle), last wake 20:18. Pre-sleep state not captured. Watcher "test9-plugged-soak" armed after the fact (fine: it waits for the Deck to come back).
- 20:20:57 suspend entry (game running). 20:22:19 suspend exit (82 s); vpower: AC 'Connected' 45 W, battery 77.7 %, 'Full'.
- 20:22:21 watcher connected (attempt 14). 20:22:32 direct read: **fan 2832 RPM, fault 0**, APU 58 C, GPU 100 %, 'Not charging', limit 60 %. **PASS.**
- Tally in the plugged + not-charging + long-sleep state: FAIL x2 (tests 1, 3; limit 72 %; charger idle 43-66 min; before 20:09 replug). PASS x3 (tests 7, 8, 9; limit 60 %; charger idle 1-13 min; after 20:09 replug). Two confounds remain between the groups: charge-limit value (72 vs 60) and charger idle time / replug. Game running or not made no difference (7 idle, 8 and 9 running, all pass).
- 20:23  Charge limit restored to 72 % (user's normal; also removes the limit confound for the next attempt). Plan: leave plugged and idle on AC for 30+ min, then a ~2 min in-game sleep (test 10).
- Test 9 capture detail (captures/test9-plugged-soak-capture.txt): first read 20:22:21.501 fan=2832 fault=0 target=0 apu=54C gpu=96% ; fan values over 45 s: 2832,2853,2828,2840,3048,3427,3504,3517,3524,3772,3989,4006

## Cross-test EC memory comparison (20:25) - 2 faulted dumps vs 7 healthy +45 s dumps (scripts/pc/ecdiff.py)

Offsets where both faulted dumps agree on a value that no healthy dump has:
- 0x39F: 02 faulted / 03 healthy (FNCK bit, known).
- 0x3B0/0x3B1: 0 faulted / RPM healthy (known).
- **0x403: 0x00 faulted / 0x1B-0x1C (27-28) healthy** - plausibly fan floor or set-point in hundreds of RPM (healthy wakes start at ~2800 RPM).
- **0x404: 0x1E (30) faulted / 0x00-0x01 healthy** - a counter that has run up to 30 and stayed there; looks like a fan-start/stall retry limit that latched.
- **0x405: 0x00 faulted / 0x02 healthy** - fan state (2 = running, 0 = stopped/failed?).
- **0x32E (EC RAM 0x2E, unnamed): 0x00 faulted / 0x26-0x5E (38-94) healthy, rising with fan speed** - plausibly fan PWM duty %.
- Page 0x400 constants in all dumps: 0x400=0x3C (60), 0x408=0x0C, 0x40A=0x07, 0x40B=0x0A, 0x40C=0x63 (99) - likely thermal thresholds.
- These offsets are unnamed in the DSDT (page 0xFE700400 only names EBID at 0x2C and BATL/BATH at 0x6E), so they are EC-internal; interpretation is inference, flagged as such.
- Action: wakecap.sh now dumps the full EC pages in the first second after resume (previously only a 3-line summary), so the next failure will show whether 0x404 is already 30 at +1.5 s or counts up. Soak logger (/home/deck/soaklog.sh -> soak.log) records fan/battery/PD state and a full EC dump every 5 min from 20:24 while plugged and idle on AC.

## Sleep test 10 - plugged, limit 72 %, not charging (0 uA), ~17 min on AC since 20:09 replug

- ~20:26  User put the Deck to sleep. Pre-sleep (20:24:00 soak log): fan 5434 RPM, fault 0, APU 75 C, 'Not charging' 0 uA, 8.284 V, PD 15 V/3 A, limit 72 %. Watcher "test10" armed. Note: the wakecap.sh full-page-at-wake edit did not apply before this sleep (SSH timed out), so first-second EC pages will again be summary only; +45 s pages are full.
- 20:24:42 suspend entry (game running, fan 5434 / 75 C at 20:24:00). 20:27:23 suspend exit (161 s); vpower: AC 'Connected' 45 W, battery 77.7 %, 'Full'.
- 20:27:24 watcher connected (attempt 33). 20:27:41 direct read: **fan 0 RPM, fault 1**, APU 66 C, GPU 62 %, 'Not charging' 0 uA, limit 72 %. **FAIL reproduced** (3rd failure).
- EC state block at 20:27:41: 0x32E=00, 0x39F=02 (FNCK 0), 0x3B0/1=0000, **0x403=00 0x404=1E 0x405=00** - identical to the two earlier faulted dumps. The 0x403-0x405 block is a reliable fault signature.
- Hypothesis update: 17 min of AC idle was enough to fail, so "needs 40+ min soak" is dropped. Tally in plugged + not charging + long sleep: **limit 72 % (battery 77-78 %): FAIL 3/3 (tests 1, 3, 10). Limit 60 % (battery 78 %): PASS 3/3 (tests 7, 8, 9).** The charge-limit value, or more precisely how far the battery sits above the limit (5-6 % vs 18 %), is now the leading discriminator. Alternative remains intermittency (3/3 vs 0/3 would be unlikely by chance, p ~ 0.05).
- Mechanism candidates: the EC's charge-limit controller may hold the battery in a different sub-state when within a few % of the limit (e.g. "maintain / top-off pending / recharge-hysteresis band") than when far above it ("charge inhibited"); the S3 resume path of the EC may behave differently in that sub-state. Test: alternate limit 60 (expect pass) and 72 (expect fail) with everything else fixed.
- User asked to send a Steam system report while faulted (per austinp-valve's request in #2475).
- 20:28:27  With the fan dead and game running: APU 90 C, GPU 99 %, sclk 1367 MHz. 20:29:21: APU 92 C. Suspended the Deck over SSH (`systemctl suspend`) at user's request for a quick recovery cycle; watcher "quick3-recovery" armed (full EC pages at +1 s now enabled).

## Sleep test 11 - quick recovery (12 s), remote suspend

- 20:29:22 suspend entry (fan dead, APU 92 C). 20:29:34 suspend exit. 20:29:54: **fan 5804 RPM, fault 0**, APU 62 C. Recovered. Capture: captures/quick3-recovery-capture.txt (first run with full EC pages at +1 s).

## Alternation test plan (everything else fixed: plugged, 45 W, battery ~78 %, game running, ~2 min sleep)
- Step 1 (test 12): limit 60 % -> predict PASS.  Step 2 (test 13): limit 72 % -> predict FAIL.
- 20:30  Limit set to 60 %. Watcher "alt1-limit60" armed.

## Expert review 1 (Steam Deck firmware reviewer) - key points accepted (20:32)

- Corrections adopted: fan1_target readback is the driver's cached value, not EC confirmation; the steamdeck-hwmon rebind was an MFD-child rebind with no EC interaction (null test); ~2800 RPM is the minimum of the EC auto curve, not a "start-up floor"; the 2.7 A seen 20 s after replug at 20:10 was a DISCHARGE (EC MCUR at EC RAM 0x83/0x84 is signed; unplugged dump shows 0xF556 = -2730 mA), i.e. the system was still running from the battery shortly after replug; FNCK's internal meaning is unknown ("fan OK" status), not proven to be a tach fault; the 0x39D and 0x344 interpretations are withdrawn entirely; test 9 was 82 s and ~11 min after plug-in (not a soak test).
- Upstream #2475 also has a cold-boot variant (power-on with AC + battery at limit -> same fault), so the trigger is the charger state, not S3 per se. Report wording to be: "EC fan controller does not start after S3 resume (and per upstream, at power-on) when AC is present and charging is inhibited by the charge limit; fan output 0 %, FNCK=0, FANS commands ignored until another S3 cycle."
- EC bytes: 0x2E = fan level in % of 7300 (0 in both faulted dumps); 0x8C bit0 = AC present; 0x8D bit6 = charge inhibited (0xC0 not charging, 0x80 charging); MCBL (XECB 0xB9F) = charge limit (0x48=72, 0x3C=60), confirming page 0xB is live; 0x12E/0x12F = 16-bit counter stepping 0x29 per plugged S3 cycle. Named-but-unused EC fields to ask Valve about: FNOV (EC RAM 0x42 bit 6), SFAN (0xF4), S3 flag bits at 0xF8. Do not write them blindly.
- Reviewer's hypothesis ranking (written before test 10): 1) time since charger connection; 2) intermittency; 3) limit/SoC margin (low, because the user's Oct 12 comment reproduced at 80 % limit with 95 % SoC). Test 10 (17 min after plug-in, limit 72, FAIL) narrows any time threshold to 12-17 min, and the alternation test separates the limit from elapsed time.
- Biggest gap: no EC snapshot at sleep entry or in the first instant of resume. Fix: systemd system-sleep hook (root) logging fan/battery/EC pages at pre and post -> /home/deck/sleephook.log. Installed 20:32.
- Report must include the Steam system report ID captured while faulted (Valve's only request) and state that the Oct 12 comment is the user's own.

## Sleep test 12 - alternation step 1: limit 60 %, plugged, not charging (0 uA), game running, ~22 min since 20:09 replug

- 20:31:11 remote suspend. Pre-sleep: fan 4934 RPM, fault 0, APU 76 C, limit 60 %, 'Not charging' 0 uA. Sleep hook active (first pre/post EC snapshots expected in /home/deck/sleephook.log). Watcher "alt1-limit60" armed. Prediction: limit hypothesis -> PASS; time-since-plug-in hypothesis (threshold 12-17 min) -> FAIL.
- 20:31:11 suspend entry. 20:33:30 suspend exit (139 s). 20:33:49: **fan 0 RPM, fault 1**, APU 74 C, GPU 100 %, 'Not charging' 0 uA, **limit 60 %**. **FAIL.** Watcher connected 20:33:31 (attempt 34).
- **Limit-value hypothesis rejected** (fails at both 72 % and 60 %). Remaining split by minutes since charger connection: PASS at 1, 7, 12 min; FAIL at 17, 22, 43, 66 min. Threshold, if real, lies between 12 and 17 min. Intermittency not excluded but 0/3 vs 4/4 split by time is now the leading explanation.
- Sleep hook did not produce pre/post entries for this cycle (only the manual test entry present). Investigating.
- 20:34:0x  While faulted: wrote fan1_target=7300 as root, then read the EC's own set-point bytes: **FSLO/FSHI (0xFE700B92/93) = 7300** (page 0xB row: `b90: 00 00 84 1c ...`). So the FANS(7300) write DID land in EC memory and the command was issued; fan still 0 RPM, FNCK 0, 0x403-0x405 = 00 1E 00. This is the direct EC-side proof the reviewer asked for: the EC receives a valid set-point and does not act on it. After FANS(0): FSLO/FSHI back to 0.
- 20:34  Charge limit restored to 72 %.
- Sleep hook: did not run. SteamOS's systemd-sleep binary (systemd 257, Valve build) only lists /usr/lib/systemd/system-sleep (strings check); /etc/systemd/system-sleep is not consulted, and /usr is read-only. Will replace with a systemd unit (Before=sleep.target, StopWhenUnneeded, ExecStart = pre snapshot, ExecStop = post snapshot).
- 20:34:41  APU **99 C**, sclk 1169 MHz, fan 0, game running. 20:34:5x: suspended remotely to protect the APU.

## Sleep test 13 - quick recovery (15 s), remote suspend

- 20:35:02 suspend entry (fan dead, APU 91 C). 20:35:17 suspend exit. 20:35:46: **fan 5822 RPM, fault 0**, APU 80 C. Recovered.
- 20:35  Installed /etc/systemd/system/fanprobe-sleep.service (Before=sleep.target, StopWhenUnneeded, WantedBy=sleep.target): ExecStart runs the snapshot script with "pre suspend" at sleep entry, ExecStop runs it with "post suspend" at resume -> /home/deck/sleephook.log. Enabled.

## Next: test the time-since-plug-in hypothesis directly (test 14)
- Charger has been connected since 20:09 (26 min). Plan: unplug ~10 s, replug, suspend immediately for ~2 min. Prediction under time hypothesis: PASS (as tests 7-9). Then, without replug, wait >= 17 min and sleep again: predict FAIL. A pass-then-fail pair with no other change would settle it.

## Expert review 2 (charging / fan-controller reviewer) - key points accepted (20:38). Written before test 12.

- Headline mechanism: a resume-time (and per upstream, boot-time) EC **fan self-check** that applies a test duty, waits a window, requires tach, and on failure sets FNCK=0 and gates output to 0 % until the next EC re-init. 0x404 = 0x1E (30) in every faulted dump reads like "30 consecutive tach-miss samples". 0x32E = fan output level (% of 7300), 0 in all faulted dumps.
- Wording fix: the EC does NOT "ignore" 0xCC/0xCD. The set-point lands (FSLO/FSHI = 7300 confirmed at 20:34; 0xB9C/0xBA0 latched 0x1C84 at 19:45). Correct statement: **the EC accepts the set-point but its fan output stays at 0 %** while the self-check failure is latched.
- Why short sleeps pass and charging passes needs a second ingredient (M2): something that happens >12 s and <91 s into S3 in the AC-present/charge-inhibited branch only. Candidates: (a) the EC dropping to its slow-clock idle loop after N s; (b) the charger IC's I2C watchdog (40/80/160 s class) expiring because the idle EC stops servicing it, so at wake the EC re-inits the charger in the window where the fan check runs. Distinguisher: **sleep-duration bisection** in the failing configuration (20/40/60/80/100 s): a step at 40/80/160 s points at the watchdog; a step elsewhere at an EC timer; a smear at chance.
- Hardware per iFixit chip ID: OLED charger = MPS MP2762A (2-cell NVDC buck-boost, I2C); EC likely ITE IT81302. LCD uses Maxim MAX77961/MAX77958. If any #2475 reporter is on an LCD unit the mechanism is EC branch logic, not a charger-IC timer -> check reporter models.
- Corrections: "firmware_version 4352" is PDFV (PD controller firmware, DSDT PDFW), not the EC version - label separately from VERN "G01100". "+1.5 s after resume" is from the kernel's suspend-exit line; the EC woke seconds earlier - say "no spin-up visible from +1.5 s". Watcher timestamps are PC time vs Deck journal time (sleep hook now removes that ambiguity). "0 mA" was measured at 19:56 and 20:24, not immediately before tests 1/3. Workaround "raise the limit" only buys one docked session.
- Safety: the game ran at 100 % GPU with the fan dead for ~20 min at 19:28-19:48 (100 C) and again briefly at 19:53 and 20:27-20:35 (92-99 C). APU throttling protects the die, not the charger IC or the OLED panel. Rule from now on: once fault=1 is confirmed (10 s is enough), close the game / suspend. Do the remaining tests with the game closed.
- Hygiene for the end: remove /etc/sudoers.d/zz-deck-nopasswd, the sleep unit/hook and the soak logger; state in the report that no EC writes were made (only /dev/mem reads, ec_sys read-only, and hwmon writes through the official interface).
- Design point for Valve: on fan-check failure the EC should fail to full duty open-loop and re-check periodically, not drive 0 % and latch until the next S3. That fix makes the bug harmless whatever the root cause.
- Added tests: T3 - from a faulted state do a LONG AC-idle sleep (fails again -> the bad path is the resume path and the fan is re-initialised at every S3 entry; recovers -> the arming condition is consumed by the fault). T4 - cold-boot variant. T5 - whether 0x32E is command or measurement (write 7300 healthy, sample 0x32E vs RPM at 200 ms).
- Hook upgraded 20:38: post-resume phase now samples fan_in/fault/0x32E/0x39F/RPM/0x403-5/0x38C-D/MCUR/FSLO-FSHI/BAT status+current every 200 ms for 5 s (ecfast.py) before the full page dump.
- Note: test 12 (limit 60, FAIL) post-dates this review and removes the limit-value split the reviewer leaned on; the time-since-plug-in split (pass 1/7/12 min, fail 17/22/43/66 min) stands and is being tested directly (test 14: replug then immediate sleep).

## Sleep test 14 - replug then immediate long sleep (time-since-plug-in test)

- 20:40:42 charger reconnected (vpower: Disconnected -> Connected). 20:40:51 remote suspend, 9 s after replug. Pre-sleep: AC on, 'Not charging' (current_now +522 mA, settling after replug), 78 %, limit 72 %, fan 3989 RPM, fault 0, APU 48 C, **game closed**. Sleep hook + 200 ms post sampler active. Watcher "test14-replug" armed; Deck down 20:40:57.
- Prediction: time-since-plug-in hypothesis -> PASS. Intermittency / M2 duration-only -> ~fail rate as before.
- 20:40:51 suspend entry. 20:42:57 suspend exit (126 s). 20:43:07: **fan 0 RPM, fault 1**, APU 43 C, 'Not charging' 0 uA, game closed. **FAIL, 9 s after replug.** Time-since-plug-in hypothesis rejected. Game-closed also fails (so test 7's pass was not due to the game being closed).
- Tally, plugged + not charging + >= 80 s sleep: FAIL 5 (tests 1, 3, 10, 12, 14), PASS 3 (tests 7, 8, 9, consecutive, all right after the unplugged test 6). Limit 72 and 60 both fail; game open/closed both fail; 9 s and 66 min after plug-in both fail.
- **First 200 ms post-resume samples of a failing wake (sleep hook, Deck clock, t=0 at ExecStop start, ~0.1 s after kernel 'suspend exit'):**
  - t=0.02-0.9 s: fan output byte 0x32E = **0x36 (54 %)**, tach 0 RPM, 0x39F = 0x08, 0x403 counts DOWN 09->06->04->02->00, 0x404 counts UP 0x15->0x18->0x1A->0x1C->**0x1E (30)**, 0x405 = 0.
  - t>=1.1 s: 0x32E = **0x00**, 0x39F = 0x02 (FNCK 0), 0x403-0x405 latched 00 1E 00. fan1_fault=1 from the first sample.
  - Interpretation: the EC runs a fan self-check at resume: it DRIVES the fan at ~54 % while counting a 30-sample window (0x404 up / 0x403 down, ~0.2 s per step => ~6 s total, so the check began ~5 s before the kernel finished resuming), gets no tach pulses, and at 30 misses gates the output to 0 % and clears the fan-OK bit. **The fan is being driven and does not turn.** Points to the fan's supply rail / driver not being enabled on this resume path (reviewer M3) rather than the EC skipping the check (M1) - subject to seeing the same window on a passing wake with tach rising.
  - Charger bytes during the window: 0x38C=01 (AC present), 0x38D=C0 (charge inhibited), MCUR 0.
- Saved /home/deck/sleephook.log to captures/sleephook-through-test14.log. Watcher "t3-long-from-faulted" armed. Next: user sends Steam system report while faulted (game closed, APU 43 C), then a 2 min sleep FROM the faulted state (reviewer T3).
- ~20:45  User sent a Steam system report from the Deck while faulted (fan 0, fault 1, game closed, APU ~43 C). This is the item austinp-valve requested in #2475.

## Sleep test 15 - reviewer T3: 2 min sleep FROM the faulted state (plugged, not charging, game closed)
- 20:46:28 pre-sleep: fan 0, fault 1, APU 53 C, 'Not charging' 0 uA, game closed. 20:46:29 suspend entry. 20:48:31 suspend exit (122 s). 20:48:32 and 20:48:53: **fan 0 RPM, fault 1**, APU 44 C. **Still faulted after a 2 min sleep from the faulted state.** A long AC-idle sleep does not clear the fault; only a short one has (tests 2, 4, 11, 13). The failing resume path is deterministic for long sleeps in this state tonight (5/5 since 20:20), while tests 7-9 earlier passed.
- User theory noted: "APU had to be hot at sleep entry" - not supported: test 14 (APU 47 C, game closed) failed; test 5 (79 C, charging) passed.
- Test 15 post-resume 200 ms samples: identical counter window (0x403 09->00, 0x404 0x15->0x1E over 0.9 s, then latched), but **0x32E = 0x00 throughout** (pre-sleep output was already 0). So the EC does not apply a dedicated test duty: it restores the pre-sleep output level (54 % in test 14, 0 % here) and runs the 30-sample tach window. Saved captures/sleephook-through-test15.log.

## Sleep test 16 - quick recovery cycle, first passing wake captured by the 200 ms hook
- 20:49:39 suspend entry (faulted). 20:49:48 suspend exit (9 s). **PASS**: at hook t=22 ms fan already 2832 RPM, 0x32E=0x26 (38 %), 0x39F=0x03, 0x403-0x405 = 1C 00 02 (28 remaining, 0 misses, state 2). The self-check had completed successfully before the kernel finished resuming. 20:49:56: fan 2897, fault 0.
- Contrast: on failing wakes the EC is still inside the 30-sample window at kernel resume (sample ~21), with the fan not turning under 54 % (test 14) or 0 % (test 15) drive. After a long sleep the EC's resume sequence is evidently later/different relative to the host's.

## Sleep-length sweep in the failing configuration (plugged, 'Not charging', limit 72 %, game closed) - automated cycles (scripts/pc/cycle.ps1), results appended below by the script
### sweep-45s : 45s sleep
- pre 20:50:54: fan=2893 fault=0 apu=42C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:51:48: fan=0 fault=1 apu=42C bat=Not charging
- 20:50:55 (deep) entry 20:51:41 exit suspend 
- hook t=0:    20 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1126 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 20:51:52: fan=0 fault=1 apu=43C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:52:13: fan=2893 fault=0 apu=42C bat=Not charging
- 20:51:52 (deep) entry 20:52:03 exit suspend 
- hook t=0:    20 |  2828 0 | 26 03 0c 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1126 |  2875 0 | 27 03 37 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4883 |  2875 0 | 27 03 3b 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
### sweep-25s : 25s sleep
- pre 20:52:28: fan=2849 fault=0 apu=42C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:53:02: fan=2884 fault=0 apu=41C bat=Not charging
- 20:52:29 (deep) entry 20:52:55 exit suspend 
- hook t=0:    21 |  2853 0 | 27 03 25 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1126 |  2871 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4890 |  2871 0 | 27 03 37 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
### sweep-35s : 35s sleep
- pre 20:53:11: fan=2897 fault=0 apu=41C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:53:55: fan=2871 fault=0 apu=40C bat=Not charging
- 20:53:12 (deep) entry 20:53:47 exit suspend 
- hook t=0:    21 |  2853 0 | 27 03 25 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2897 0 | 27 03 51 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4893 |  2871 0 | 27 03 37 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
### sweep-40s : 40s sleep
- pre 20:54:04: fan=2875 fault=0 apu=40C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:54:52: fan=841 fault=0 apu=40C bat=Not charging
- 20:54:04 (deep) entry 20:54:45 exit suspend 
- hook t=0:    20 |  2840 0 | 26 03 18 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2871 0 | 27 03 3b 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |  2893 0 | 27 03 4d 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
### sweep-43s : 43s sleep
- pre 20:55:28: fan=2875 fault=0 apu=40C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:56:23: fan=0 fault=1 apu=40C bat=Not charging
- 20:55:29 (deep) entry 20:56:14 exit suspend 
- hook t=0:    22 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1129 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4887 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 20:56:27: fan=0 fault=1 apu=41C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:56:47: fan=2875 fault=0 apu=41C bat=Not charging
- 20:56:27 (deep) entry 20:56:37 exit suspend 
- hook t=0:    20 |  2840 0 | 26 03 18 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1126 |  2884 0 | 27 03 44 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4883 |  2862 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- **Sweep summary so far (actual sleep length from journal entry->exit):** 9 s PASS, 10 s PASS, 11 s PASS, 26 s PASS, 35 s PASS, 41 s PASS, **45 s FAIL**, 46 s FAIL, 82-161 s FAIL (x7). Sharp edge between 41 and 45 s of S3 in the plugged / 'Not charging' state. Every failing wake shows the identical hook signature (t=0: out=pre-sleep level, 0x39F=08, counters 09/15; t>=1.1 s: out=0, 0x39F=02, counters 00/1E); every passing wake shows the check already complete at t=0 (1C 00 02, fan ~2850 RPM).
### sweep-43s-actual-target : 41s sleep
- pre 20:57:03: fan=2884 fault=0 apu=41C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:57:54: fan=0 fault=1 apu=40C bat=Not charging
- 20:57:03 (deep) entry 20:57:47 exit suspend 
- hook t=0:    21 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1128 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4900 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 20:57:58: fan=0 fault=1 apu=41C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 20:58:15: fan=2897 fault=0 apu=40C bat=Not charging
- 20:57:58 (deep) entry 20:58:08 exit suspend 
- hook t=0:    20 |  2819 0 | 26 03 03 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2871 0 | 27 03 37 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4884 |  2897 0 | 27 03 51 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- 44 s actual sleep (20:57:03->20:57:47): **FAIL**, same signature. **Threshold is between 41 s (pass) and 44 s (fail) of S3** in the plugged / 'Not charging' state - a sharp edge, consistent with a fixed timer (reviewer 2's M2: EC idle timer or a ~40 s charger-watchdog class event, with a few seconds of suspend-entry latency before the EC's own S3 clock starts).
- Control planned: same ~60 s sleep while CHARGING (limit 100 %) -> expect PASS if the timer only arms in the charge-inhibited branch.
### control-charging-60s : 58s sleep
- pre 20:58:44: fan=2884 fault=0 apu=41C bat=Charging cur=532000uA ac=1 limit=100% game=0
- post 20:59:51: fan=0 fault=0 apu=40C bat=Charging
- 20:58:45 (deep) entry 20:59:44 exit suspend 
- hook t=0:    20 |  2884 0 | 27 03 44 0b | 1c 00 02 | 01 80 3e 0f | 00 00 | Charging/3902000
- hook t=1.1s:  1127 |  2884 0 | 27 03 44 0b | 1c 00 02 | 01 80 33 0f | 00 00 | Charging/3891000
- hook t=4.9s:  4892 |  2074 0 | 1c 03 1a 08 | 1c 00 02 | 01 80 34 0f | 00 00 | Charging/3885000
- RESULT: PASS
- **Control, charging (limit 100 %, +0.5 A at entry): 59 s sleep (20:58:45->20:59:44) -> PASS.** Hook t=0: fan 2884, out 0x27, counters 1C 00 02, charger bytes 0x38D=0x80 (charging), MCUR +3.9 A. Same duration range that fails 3/3 when not charging. The threshold belongs to the charge-inhibited branch only.
- Note: at +6 s the fan read 0 RPM with fault 0 and output ramping down (0x1C at +4.9 s): the EC legitimately parks the fan at cool idle (40 C) while charging. Not a fault.
- 21:01  Charge limit restored to 72 %. Fan steady 2862 RPM at idle (the 0 RPM / 841 RPM readings at +6 s after two passing wakes were transient tach reads; output byte stayed 39 %).
- 21:02  Report rewritten in full with both reviews' corrections and the sweep: H:\steamdeck\valve-report-draft.md. Still needs: SteamID64; confirmation of the system-report time; cleanup of the Deck (sudo rule, sleep unit, soak logger) once testing is declared finished.

## Web research (21:1x) - prior art beyond #2475

- Steam Community bug report "Sleep/Wake while docked/charging disables fan leading to thermal throttling" (wampa007, Jan 2 2026, 56 replies): https://steamcommunity.com/app/1675200/discussions/1/686367878797224510/ . Same recipe: plugged in, battery full / at limit, heavy game, sleep, wake after 15-20 s or more -> fan 0 RPM, 100 C, GPU 200 MHz. OP's workaround: sleep/wake within ~7 s, or unplug then sleep/wake. OP: "never reproduced while unplugged"; "an 18 W charger does not trigger it". Replies from at least 8 other users, several explicitly OLED (Skyllus, IDaPrc, The Real Marko 1 TB OLED Dec 2025, Thegamingboy docked+PD). IDaPrc: `sensors` shows "SYSTEM Fan FAULT", suspects EC firmware; for them only a full shutdown clears it. Support offered wampa007 a warranty repair; OP declined pending a software fix. No Valve staff reply in the first 15 comments.
- Note the OP's "cools more than 10-15 C before wake" matches our 41-44 s edge (the Deck cools roughly that much in ~45 s): our sweep shows it is time asleep, not temperature, that matters (tests at 40-41 C idle fail at 44 s and pass at 41 s with no meaningful temperature change).
- Search result summary also mentioned a user whose RMA "came back unfixed" and another whose replacement unit developed the same problem (source thread not yet pinned down; checking the remaining pages of the thread).
- No SteamOS 3.8.x / 3.9 beta release note mentions this. 3.8.28 fixed an unrelated fan issue (fan speed reverting to BIOS control until reboot).

## Desktop Mode tests (2026-10-14 21:55)

User switched to Desktop Mode (plasmashell session, no game). Plugged in, 'Not charging' at 79 %, limit 72 %, fan 2757 RPM, fault 0. Same cued cycle script (user presses power button on cue).

### desktop-90s : 90s sleep
- pre 21:55:37: fan=2757 fault=0 apu=42C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 21:57:16: fan=0 fault=1 apu=39C bat=Not charging
- 21:55:38 (deep) entry 21:57:09 exit suspend 
- hook t=0:    21 |     0 1 | 25 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1129 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4898 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 21:57:20: fan=0 fault=1 apu=39C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 21:57:38: fan=2884 fault=0 apu=39C bat=Not charging
- 21:57:20 (deep) entry 21:57:31 exit suspend 
- hook t=0:    21 |  2811 0 | 26 03 fb 0a | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2862 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4898 |  2875 0 | 27 03 3b 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
### desktop-48s : 48s sleep
- pre 21:57:46: fan=2862 fault=0 apu=39C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 21:58:43: fan=0 fault=1 apu=38C bat=Not charging
- 21:57:47 (deep) entry 21:58:36 exit suspend 
- hook t=0:    21 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4896 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 21:58:47: fan=0 fault=1 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 21:59:08: fan=2875 fault=0 apu=39C bat=Not charging
- 21:58:47 (deep) entry 21:58:58 exit suspend 
- hook t=0:    20 |  2832 0 | 26 03 03 0b | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2871 0 | 27 03 3b 0b | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4890 |  2862 0 | 27 03 2e 0b | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
### desktop-36s : 36s sleep
- pre 21:59:13: fan=2884 fault=0 apu=39C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:00:01: fan=2875 fault=0 apu=38C bat=Not charging
- 21:59:14 (deep) entry 21:59:52 exit suspend 
- hook t=0:    20 |  2806 0 | 26 03 f6 0a | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1129 |  2849 0 | 27 03 21 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4899 |  2862 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
- **Desktop Mode summary:** 91 s FAIL, 49 s FAIL, 38 s PASS; 11 s recovery worked both times. Hook signature identical to Game Mode failures (t=0 out=pre-sleep level, 0x39F=08, counters 09/15; latched out=0, 0x39F=02, counters 00/1E by t=1.1 s). Desktop vs Game Mode makes no difference: the session layer (gamescope/Steam client vs Plasma) is not involved, consistent with an EC-side cause.

## Full reboot test (2026-10-14 22:01)

User requested a full reboot, then repeat the recipe from a fresh boot. Reboot issued over SSH.

### postreboot-50s : 50s sleep
- pre 22:02:10: fan=2849 fault=0 apu=44C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:03:09: fan=0 fault=1 apu=42C bat=Not charging
- 22:02:10 (deep) entry 22:03:02 exit suspend 
- hook t=0:    20 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1134 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 22:03:12: fan=0 fault=1 apu=43C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:03:33: fan=0 fault=0 apu=45C bat=Not charging
- 22:03:13 (deep) entry 22:03:23 exit suspend 
- hook t=0:    20 |  2005 0 | 1b 03 d5 07 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1125 |   273 0 | 03 03 11 01 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4882 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- **Post-reboot summary:** first full reboot since 2026-10-12 19:22 (all earlier tests were on that one boot). Booted to Game Mode, 'Not charging' 79 %, limit 72 %. 52 s sleep (22:02:10->22:03:02): **FAIL**, identical hook signature. 10 s recovery cleared the fault; output briefly ramped to 0 (0x39F=03, counters 1C 00 02, i.e. check passed) and the fan was back at ~2880 RPM by +12 s. A fresh boot does not prevent the fault.

## Full shutdown test (2026-10-14 22:05)

Reboot may not reset the EC, so: poweroff over SSH, user waits ~30 s and powers on (still plugged in, at limit). Check fan right after boot (cold-boot variant), then repeat ~50 s recipe.

- Off 22:06:00 -> boot 22:06:24 (~24 s powered off, plugged in). At +9 s uptime: fan 2483 RPM, fault 0, APU 48 C, 'Not charging' 79 %, limit 72 %. **Cold-boot variant does not reproduce here.**
### postshutdown-50s : 50s sleep
- pre 22:06:52: fan=3524 fault=0 apu=46C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:07:51: fan=0 fault=1 apu=44C bat=Not charging
- 22:06:53 (deep) entry 22:07:44 exit suspend 
- hook t=0:    20 |     0 1 | 30 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1128 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4888 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 22:07:54: fan=0 fault=1 apu=45C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:08:12: fan=2884 fault=0 apu=45C bat=Not charging
- 22:07:55 (deep) entry 22:08:05 exit suspend 
- hook t=0:    20 |  2819 0 | 26 03 03 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1134 |  2862 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4900 |  2871 0 | 27 03 37 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- 51 s sleep (22:06:53->22:07:44) after the full shutdown: **FAIL**, identical hook signature; 10 s recovery worked (2884 RPM). Caveat: the Deck stayed plugged in while off, so the EC was likely still powered for charger supervision; this is not a guaranteed EC reset (that would need shutdown + unplug, or battery storage mode).

## Shutdown + unplug test (2026-10-14 22:09)

Poweroff over SSH; user unplugs, waits ~30 s, powers on unplugged, then plugs back in. Then ~50 s recipe.

- Off 22:09:32 -> boot 22:10:34 unplugged (~62 s off with no AC). At +8 s: AC 0, fan 2309 RPM, fault 0, Discharging 79 %. Charger reconnected ~22:11:40; 'Not charging' by 22:11:54.
### postunplug-shutdown-50s : 50s sleep
- pre 22:12:05: fan=2806 fault=0 apu=42C bat=Not charging cur=691000uA ac=1 limit=72% game=0
- post 22:13:03: fan=2884 fault=0 apu=40C bat=Not charging
- 22:12:05 (deep) entry 22:12:56 exit suspend 
- hook t=0:    21 |  2840 0 | 26 03 18 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1128 |  2875 0 | 27 03 3b 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4895 |  2893 0 | 27 03 4d 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
### postunplug-shutdown-50s-repeat : 50s sleep
- pre 22:13:20: fan=2862 fault=0 apu=40C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:14:19: fan=0 fault=1 apu=40C bat=Not charging
- 22:13:20 (deep) entry 22:14:12 exit suspend 
- hook t=0:    20 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 22:14:22: fan=0 fault=1 apu=40C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:14:41: fan=0 fault=0 apu=41C bat=Not charging
- 22:14:23 (deep) entry 22:14:34 exit suspend 
- hook t=0:    20 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1130 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4904 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- 51 s sleep at 22:12:05, ~25 s after replug: **PASS**. Status read 'Not charging' but current_now was +691 mA at entry (battery still taking charge after replug).
- Repeat at 22:13:20 with current_now = 0: 52 s sleep **FAIL**, identical signature. So the shutdown + unplug (EC presumably unpowered from AC; ~62 s off) did not clear anything; the pass was most likely the post-replug charge current. This may also explain tests 7-9 (consecutive passes after an unplug/replug), though test 14 (9 s after replug) failed and its entry current was not recorded.
- Recovery (11 s) cleared fault but restored output 0 % (pre-sleep level, counters 1C 00 02 = check passed); fan resumed ~2840 RPM about 20 s after wake.
- **Conclusion:** reboot, full poweroff with AC, and poweroff + unplug all leave the recipe intact. Only active charge current at sleep entry prevents it.

## Battery pack test (2026-10-14 22:21)

User plugged a USB-C battery pack. PD contract from EC (0xFE700C56..59, PDVL x50 mV / PDAM x10 mA): **12 V / 1.67 A (20 W)** vs 15 V / 3 A with the 45 W charger. current_now ~490 mA for ~40 s after plug-in, then 0 at 22:21:27 ('Not charging', 79 %, limit 72 %).

### batterypack-12V-50s : 50s sleep
- pre 22:21:34: fan=2849 fault=0 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:22:33: fan=2875 fault=0 apu=37C bat=Not charging
- 22:21:34 (deep) entry 22:22:26 exit suspend 
- hook t=0:    20 |  2798 0 | 26 03 ee 0a | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1126 |  2862 0 | 27 03 2e 0b | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |  2884 0 | 27 03 44 0b | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
### batterypack-12V-90s : 90s sleep
- pre 22:22:40: fan=2897 fault=0 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:24:20: fan=2871 fault=0 apu=36C bat=Not charging
- 22:22:41 (deep) entry 22:24:13 exit suspend 
- hook t=0:    20 |  2790 0 | 26 03 e6 0a | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |  2840 0 | 26 03 18 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4894 |  2862 0 | 27 03 2e 0b | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
- 52 s sleep (22:21:34->22:22:26), 0 mA at entry: **PASS** (hook t=0 fan 2798, counters 1B 01 02, 0x38C/D = 01 c0 = AC present + charge inhibited, same as failing 15 V runs).
- 92 s sleep (22:22:41->22:24:13), 0 mA at entry: **PASS** (counters 1C 00 02).
- Pack did not drop out during sleep as far as the host can see: no AC change events, vpower 'Connected at 20.04 W' after both resumes, EC PD bytes still 12 V/1.67 A in the pre/post hook dumps. vpower battery % flat across the 92 s sleep (78.71 -> 78.71), same as the failing 45 W sleep (78.85 -> 78.85). The 78.82 -> 78.71 step spans the post-plug-in settling period plus the first sleep, so the first pass is slightly less clean than the second.
- **Result: with a 12 V / 20 W PD source, the same 'AC present, charge inhibited' state passes 2 of 2 at 52 s and 92 s, where 15 V / 45 W fails reliably.** The failing branch depends on the PD contract (voltage or power level), not just on charge inhibit. Suggested control: back-to-back 45 W run.
### control-45W-15V-50s : 50s sleep
- pre 22:25:55: fan=2862 fault=0 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:26:54: fan=0 fault=1 apu=38C bat=Not charging
- 22:25:55 (deep) entry 22:26:47 exit suspend 
- hook t=0:    20 |     0 1 | 27 08 00 00 | 09 15 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4886 |     0 1 | 00 02 00 00 | 00 1e 00 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: FAIL
- recovery cycle (8 s):
- pre 22:26:58: fan=0 fault=1 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:27:18: fan=0 fault=0 apu=39C bat=Not charging
- 22:26:58 (deep) entry 22:27:08 exit suspend 
- hook t=0:    20 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1127 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4893 |     0 0 | 00 03 00 00 | 1c 00 02 | 01 c0 00 00 | 00 00 | Not charging/0
- recovered
- **Back-to-back control, 45 W charger (PD 15 V / 3 A, 0 mA, 'Not charging'):** 52 s sleep (22:25:55->22:26:47) **FAIL**, identical signature. 10 s recovery cleared the fault (output restored at 0 %, fan restarts on its own ~20 s later).
- **Conclusion:** same Deck, same boot, same battery level, same charge-inhibited state, minutes apart: 12 V / 20 W PD source passes 2/2, 15 V / 45 W fails. The PD contract decides it.

## Second 20 W source: wall charger (2026-10-14 22:29)

User plugged a different wall charger. PD contract 12 V / 1.67 A (20 W), same as the battery pack. 'Not charging', 0 mA. A wall charger should not auto-shut-off at low load, so this checks the pack-dropout explanation.

### wall-20W-12V-50s : 50s sleep
- pre 22:29:17: fan=2862 fault=0 apu=38C bat=Not charging cur=0uA ac=1 limit=72% game=0
- post 22:30:17: fan=0 fault=0 apu=38C bat=Not charging
- 22:29:18 (deep) entry 22:30:10 exit suspend 
- hook t=0:    21 |   673 0 | 09 03 a1 02 | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=1.1s:  1128 |     0 0 | 00 03 00 00 | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- hook t=4.9s:  4892 |     0 0 | 00 03 00 00 | 1b 01 02 | 01 c0 00 00 | 00 00 | Not charging/0
- RESULT: PASS
- 52 s sleep (22:29:18->22:30:10), 0 mA at entry: **PASS** (fault 0; counters 1B 01 02, 0x39F = 03 = check passed; 0x38C/D = 01 c0). Output was ramping down at wake (0x09 -> 0x00, fan 673 -> 0 RPM) and the fan idled at 0 RPM until 22:31:00 (APU 38-40 C), then resumed ~2850 RPM by itself. Same cool-idle stop as the charging control and some recoveries; not a fault.
- **20 W / 12 V now passes 3 of 3 across two different sources (battery pack x2, wall charger x1); 45 W / 15 V fails.** Rules out the battery pack dropping output during sleep as the explanation.

## Second Deck (deck2: OLED 512 GB) - 2026-10-14 23:04

Same firmware as deck (SteamOS 3.8.28 build 20260922.1, BIOS F7G0114, EC VERN G011, PDFV 0x1100, board_id 5). Differences: battery VDL-M (deck: ATC), Kingston 512 GB SSD, jupiter-fan-control active (updated fan control on). Desktop Mode. 45 W charger, PD 15 V / 3 A. Charge limit set to 40 % via sysfs at 23:03:48 (Steam UI min is 50 %); battery 45 %, Not charging, 0 mA. No sleep hook on deck2 (hook lines in results will be blank). Temporary NOPASSWD sudo rule /etc/sudoers.d/zz-deck-nopasswd added by user.

### deck2-45W-50s : 50s sleep
- pre 23:05:06: fan=1938 fault=0 apu=42C bat=Not charging cur=0uA ac=1 limit=40% game=0
- post 23:06:07: fan=2087 fault=0 apu=41C bat=Not charging
- 23:05:06 (deep) entry 23:05:58 exit suspend 
- hook t=0: 
- hook t=1.1s: 
- hook t=4.9s: 
- RESULT: PASS
- deck2 52 s sleep (23:05:06->23:05:58) with jupiter-fan-control ACTIVE, 45 W / 15 V, Not charging, 0 mA: **PASS** (fan 2087 RPM, fault 0).
- 23:07 stopped jupiter-fan-control on deck2 to match deck (EC curve).
### deck2-45W-50s-fancontrol-off : 50s sleep
- pre 23:06:38: fan=2798 fault=0 apu=40C bat=Not charging cur=0uA ac=1 limit=40% game=0
- post 23:07:40: fan=2840 fault=0 apu=39C bat=Not charging
- 23:06:38 (deep) entry 23:07:30 exit suspend 
- hook t=0: 
- hook t=1.1s: 
- hook t=4.9s: 
- RESULT: PASS
- deck2 52 s sleep (23:06:38->23:07:30), jupiter-fan-control STOPPED (EC curve, like deck): **PASS** (fan 2840 RPM, fault 0). Fan-control mode is not the difference.
### deck2-45W-120s-fancontrol-off : 120s sleep
- pre 23:07:54: fan=2849 fault=0 apu=39C bat=Not charging cur=0uA ac=1 limit=40% game=0
- post 23:10:06: fan=2806 fault=0 apu=36C bat=Not charging
- 23:07:55 (deep) entry 23:09:56 exit suspend 
- hook t=0: 
- hook t=1.1s: 
- hook t=4.9s: 
- RESULT: PASS
- deck2 121 s sleep (23:07:55->23:09:56), fan control stopped: **PASS**. deck2 is 3/3 pass on the SAME 45 W charger that fails on deck (user confirmed). deck2 battery 7.768 V at 45 % vs deck ~8.28 V at 79 %.
- 23:11 raised deck2 limit to 79 % (sysfs) to charge it to deck's level; jupiter-fan-control still stopped.
- 23:13 transient unit fantest-inhibit.service on deck2 (systemd-inhibit sleep:idle, 90 min) so Desktop Mode doesn't auto-sleep while charging. Must be stopped before the next test (sudo systemctl stop fantest-inhibit).
- Firmware comparison deck vs deck2 (23:2x): identical SteamOS 3.8.28/20260922.1, kernel, BIOS F7G0114 (2026-02-05), EC VERN G01100, PDFV 0x1100, VBIOS 113-AMDSphJupiter-002, SMU 63.17.0, DMCUB 0x0300000a, all amdgpu fw (hash match), APU microcode 0x8901007, Wi-Fi fw 0x11087fff. Different: Steam client (deck 1791918634, deck2 1788652215), SSD fw (different drives), battery pack F7G-T0A 'ATC' vs F7G-M0A 'VDL-M' (different gauge data blocks). Not readable: battery gauge fw version, controller MCU fw, display bridge fw.
- 23:21 deck2 at 57 %: limit set to 50 % (sysfs) so it is Not charging, 0 mA, 8.094 V; fantest-inhibit stopped; jupiter-fan-control still stopped.
### deck2-45W-50s-57pct : 50s sleep
- pre 23:21:47: fan=2709 fault=0 apu=42C bat=Not charging cur=0uA ac=1 limit=50% game=0
- post 23:22:45: fan=0 fault=0 apu=41C bat=Not charging
- 23:21:47 (deep) entry 23:22:38 exit suspend 
- hook t=0: 
- hook t=1.1s: 
- hook t=4.9s: 
- RESULT: PASS
- deck2 52 s sleep (23:21:47->23:22:38) at 57 % / 8.09 V, 45 W 15 V, Not charging 0 mA, fan control stopped: **PASS** (fault 0; fan idle-stopped ~20 s after wake then resumed ~2850 RPM). deck2 now 4/4 pass.
- 23:24 limit back to 79 %, fantest-inhibit restarted, charging resumed.
### deck2-45W-50s-63pct-gamemode : 50s sleep
- pre 23:31:19: fan=2705 fault=0 apu=43C bat=Not charging cur=0uA ac=1 limit=50% game=0
- post 23:32:16: fan=2849 fault=0 apu=42C bat=Not charging
- 23:31:19 (deep) entry 23:32:09 exit suspend 
- hook t=0: 
- hook t=1.1s: 
- hook t=4.9s: 
- RESULT: PASS
- deck2 50 s sleep (23:31:19->23:32:09) at 63 % / 8.241 V, Game Mode, 45 W 15 V, Not charging 0 mA, fan control stopped: **PASS** (fan 2849 RPM at +7 s, fault 0). deck2 now 5/5 pass.
- 23:35 user ended deck2 testing (not reproducible: 5/5 pass at 45-63 %, 50-121 s, Desktop and Game Mode, fan control on and off, same 45 W charger). 79 % comparison not completed. deck2 restored: charge limit 100 %, jupiter-fan-control started, fantest-inhibit stopped, sudoers rule removed (sudo now asks for password). Left: sshd enabled at boot (user request), PC key in ~/.ssh/authorized_keys, deck2 entry in PC ~/.ssh/config.
- 23:4x deck2 further cleanup: PC key removed from deck2 authorized_keys, deck2 entry removed from PC ssh config and known_hosts. User to disable sshd on deck2 themselves (needs password).
