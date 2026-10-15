# Steam Deck OLED: fan stays off after waking from sleep on a 45 W charger

On my Steam Deck OLED, the fan sometimes doesn't come back after the Deck wakes from sleep. It stays at 0 RPM, SteamOS shows a fan fault, and the Deck heats up fast. I've seen the APU reach 100 °C in a game before I noticed.

This repo has a reliable way to reproduce it, what the fan controller (EC) does at the moment it fails, and all the logs and data behind it. It follows up on [ValveSoftware/SteamOS#2475](https://github.com/ValveSoftware/SteamOS/issues/2475).

- **New here?** Read this page.
- **Valve / firmware engineers:** [REPORT.md](REPORT.md) has the full technical write-up: register-level traces, the complete test table, and ACPI analysis.

## How to reproduce

1. Plug the Deck into a **45 W (15 V) USB-C charger**.
2. Make sure the battery is above its charge limit, so it shows **"Not charging"**.
3. Put it to sleep for **at least 44 seconds**, then wake it.
4. The fan stays at 0 RPM and `fan1_fault` reads 1.

To recover, put it to sleep for about 10 seconds and wake it again.

This reproduces reliably on my Deck. A second Deck with the same firmware didn't reproduce it (see [Second Deck](#second-deck-same-firmware-same-charger-no-problem)).

## The short version

1. **It's reproducible.** Plugged in to the 45 W charger, at the charge limit, sleeping 44 seconds or more: the fan stays off after waking.
2. **It doesn't happen** if the sleep is 41 seconds or less, if the battery is charging, or if the Deck is unplugged.
3. **The charger matters.** On two different 20 W (12 V) USB-C sources, a battery pack and a wall charger, it didn't happen, 3 out of 3 times, in the same state. Switching back to the 45 W charger a few minutes later, it failed again right away.
4. **Nothing in SteamOS fixes it.** Restarting the fan service, setting the fan to max, or sleeping for another couple of minutes all leave the fan off. Only a **short sleep (about 10 seconds)** brings it back, every time.
5. **It isn't Game Mode or a stuck state.** It happens in Desktop Mode too, and after a full reboot, a full shutdown, or a shutdown with the charger unplugged.
6. **SteamOS isn't told about it.** There are no errors in the logs, and the firmware gives the OS no way to reset the fan or find out it has failed.
7. **A second Deck doesn't do it.** Another Steam Deck OLED with exactly the same firmware, on the same 45 W charger in the same state, passed 5 out of 5 times. The only difference software can see is the battery: mine is `F7G-T0A` ("ATC"), the other is `F7G-M0A` ("VDL-M").

## Test results (2026-10-14)

| Situation | Sleep length | Result |
|---|---|---|
| 45 W charger, not charging | 44 s to 161 s | **Fan off** in 17 of 20 tries, and in every one of the last 14 |
| 45 W charger, not charging | 26 s to 41 s | Fan fine every time |
| 45 W charger, not charging, fan already off | about 2 min | **Still off** |
| 45 W charger, not charging, fan already off | 4 s to 15 s | **Fan back on** every time |
| 45 W charger, charging | 59 s and 124 s | Fan fine |
| Unplugged | 130 s and 96 min | Fan fine |
| Desktop Mode, 45 W charger, not charging | 49 s and 91 s | **Fan off** both times |
| Desktop Mode, 45 W charger, not charging | 38 s | Fan fine |
| First sleep after a full reboot | 52 s | **Fan off** |
| First sleep after a full shutdown | 51 s | **Fan off** |
| Powering on while plugged in, not charging (no sleep) | none | Fan fine |
| After a shutdown with the charger unplugged, then replugged | 51 s and 52 s | Fine the first time (battery was still taking a little charge), **fan off** the second time |
| 20 W battery pack (12 V), not charging | 52 s and 92 s | Fan fine both times |
| Back on the 45 W charger (15 V) right after | 52 s | **Fan off** |
| 20 W wall charger (12 V), not charging | 52 s | Fan fine |

The cutoff is sharp: 41 seconds always worked and 44 seconds always failed. Whether a game was running, how hot the Deck was, the charge limit setting (60 % or 72 %), and how long it had been plugged in made no difference. The full test-by-test table is in [REPORT.md](REPORT.md).

## Second Deck: same firmware, same charger, no problem

I also tested a second Steam Deck OLED (512 GB). Its firmware is identical to mine: same SteamOS build, BIOS, fan controller (EC), USB-C controller and GPU firmware. I used the same 45 W charger, with the battery "Not charging" and no current flowing.

| Sleep | Battery | Mode | Result |
|---|---|---|---|
| 52 s | 45 % | Desktop, updated fan control on | Fan fine |
| 52 s | 45 % | Desktop, updated fan control off (like mine) | Fan fine |
| 121 s | 45 % | Desktop | Fan fine |
| 52 s | 57 % | Desktop | Fan fine |
| 50 s | 63 % | Game | Fan fine |

The temperatures were the same range where mine fails, so that isn't the difference. The hardware differences software can see are the battery pack (**F7G-T0A "ATC"** in mine, **F7G-M0A "VDL-M"** in the other), the RAM maker and the SSD. The fan itself can't be identified from software. I didn't get to test the second Deck with its battery at my level (about 79 %).

Full comparison: [`data/second-deck/`](data/second-deck/).

## What happens as the Deck wakes up

I recorded the fan controller (EC) five times a second as the Deck woke up.

**When it fails:** the EC turns the fan back on at its pre-sleep speed and checks whether it's actually spinning. It isn't. The speed sensor reads 0 RPM for the whole check. After about 6 seconds the EC gives up, sets the fan power to 0 %, and marks the fan as faulted. It stays that way until the next short sleep.

**When it works:** the same check has already passed by the time the Deck finishes waking, and the fan is spinning at around 2850 RPM.

So the EC isn't refusing to run the fan. It powers the fan, the fan doesn't turn, and the EC then shuts it off and never tries again.

## What I tried while the fan was off

None of these brought the fan back:

- Restarting the fan control service (it set the fan to max speed, but the fan stayed off)
- Turning the fan service off and on again
- Setting the fan speed directly as root (I confirmed the EC received the request, but it kept the fan off)
- Sleeping again for 2 minutes

The workaround suggested earlier in #2475 (restarting `jupiter-fan-control` after resume) won't help with this version of the problem.

## My best guess

Waking up after 44+ seconds of sleep, on the 45 W charger with charging switched off, leaves the fan without power, or the EC checks the fan before its power is ready. The sharp 41 to 44 second cutoff suggests a fixed timer inside the EC that kicks in during sleep. Since 12 V / 20 W sources avoid it and the 15 V / 45 W charger triggers it, that path seems to depend on the charger's voltage or power level. The EC's fan settings are identical whether the fan is working or broken, so it's the EC's current state that changes, not its configuration.

Since a second Deck with the same firmware doesn't do it, it also depends on something in my unit's hardware. The battery pack is my main suspect, because the bug only happens in a charging state, and the battery is part of that circuit. Several other people report the same symptom, so it may be a part variant that the firmware handles badly rather than a one-off defect, but I can't prove that from here.

## What I'm asking Valve for

1. **Fix the wake-up bug.** Also, if the fan check fails, run the fan at full speed and keep re-checking, instead of leaving it off. That alone would make this harmless no matter what causes it.
2. **Give SteamOS a way to reset the fan,** or have the EC tell SteamOS when the fan fails, so it can react.
3. Is there an EC changelog covering fan behavior after sleep?
4. Does the EC handle the two battery variants (`F7G-T0A` and `F7G-M0A`) differently when charging is switched off?

## Workaround for now

If the Deck has slept for more than about 40 seconds while plugged in at its charge limit, put it to sleep for about 10 seconds and wake it again before playing. A 20 W USB-C charger also avoided it in my testing. Raising the charge limit only helps until the battery reaches the new limit.

## My Deck

- Steam Deck OLED, 1 TB
- SteamOS 3.8.28 stable (build 20260922.1), kernel 6.18.50-valve2-1-neptune
- BIOS F7G0114, EC firmware G01100
- Default fan curve
- Charge limit 72 % (also tested 60 % and 100 %)
- 45 W charger (USB-PD 15 V / 3 A)
- No mods. I added temporary logging tools for this testing only (in [`scripts/deck/`](scripts/deck/)).

I sent a Steam system report from the Deck **while the fan was broken**, on 2026-10-14 at about 20:45 EDT.

## What's in this repo

| Path | What it is |
|---|---|
| [`REPORT.md`](REPORT.md) | Full technical report for Valve: complete test table, 200 ms EC traces, register analysis, ACPI notes |
| [`LOG.md`](LOG.md) | Raw timestamped working log of the whole investigation, in order |
| [`data/sleep-hook/`](data/sleep-hook/) | The main dataset: EC and fan snapshots at every sleep, plus 5 seconds of 200 ms samples after every wake, from 20:31 onward |
| [`data/wake-captures/`](data/wake-captures/) | Earlier per-test captures from a PC-side watcher (1 s samples after the Deck reconnected) |
| [`data/ec-dumps/`](data/ec-dumps/) | EC memory dumps with the fan broken and working, and a diff of the two |
| [`data/acpi/`](data/acpi/) | The Deck's DSDT (ACPI table), raw and disassembled |
| [`data/soak/`](data/soak/) | 5-minute idle samples while plugged in |
| [`data/second-deck/`](data/second-deck/) | Second Deck's test results, and a firmware and hardware comparison of both units, including battery data |
| [`scripts/deck/`](scripts/deck/) | Scripts that ran on the Deck: the sleep hook and its systemd unit, and the EC samplers |
| [`scripts/pc/`](scripts/pc/) | PC scripts: `cycle.ps1` runs one cued sleep/wake test and records the result |

## How I tested

Everything was done over SSH. I only read EC memory and never wrote to it. The only fan commands I sent went through the normal SteamOS fan interface. The wake-up recordings come from a small root script that runs automatically when the Deck goes to sleep and wakes up. The charger's voltage and current were read from the EC.
