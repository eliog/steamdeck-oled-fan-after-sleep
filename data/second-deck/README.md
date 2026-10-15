# Second unit (Steam Deck OLED 512 GB)

Tested 2026-10-14 23:05 to 23:32 on a second Steam Deck OLED with identical firmware, using the **same 45 W charger** that fails on the main unit. No sleep hook was installed on it. Results come from `fan1_input` / `fan1_fault` about 7 s after resume, then sampled for up to a minute. Charge inhibit came from writing `max_battery_charge_level` below the current level, and every run waited for `current_now` = 0. The per-run raw lines are in [`../../LOG.md`](../../LOG.md) under "Second Deck".

## Results: 5 of 5 pass

| # | Sleep | Battery | Mode | jupiter-fan-control | PD contract | APU at entry | Result |
|---|---|---|---|---|---|---|---|
| 1 | 52 s | 45 % | Desktop | running | 15 V / 3 A | 42 °C | pass (2087 RPM) |
| 2 | 52 s | 45 % | Desktop | stopped | 15 V / 3 A | 40 °C | pass (2840 RPM) |
| 3 | 121 s | 45 % (7.77 V) | Desktop | stopped | 15 V / 3 A | 39 °C | pass (2806 RPM) |
| 4 | 52 s | 57 % (8.09 V) | Desktop | stopped | 15 V / 3 A | 42 °C | pass (idle stop ~20 s, then ~2850 RPM; fault 0) |
| 5 | 50 s | 63 % (8.24 V) | Game | stopped | 15 V / 3 A | 43 °C | pass (2849 RPM) |

Not done: a run with the battery at the main unit's level (77 to 80 %, ~8.3 V).

## Firmware: identical

| | Main unit (1 TB) | Second unit (512 GB) |
|---|---|---|
| SteamOS | 3.8.28 stable, build 20260922.1 | same |
| Kernel | 6.18.50-valve2-1-neptune-618-gc7289a96b14d | same |
| BIOS | F7G0114 (2026-02-05) | same |
| EC (VERN, EC RAM 0xFA) | G01100 | same |
| PD controller (PDFV) | 0x1100 | same |
| board_id | 5 | same |
| VBIOS | 113-AMDSphJupiter-002 | same |
| SMU | 63.17.0 (0x063f1100) | same |
| DMCUB / other amdgpu firmware | 0x0300000a / identical (hash of amdgpu_firmware_info match) | same |
| APU microcode | 0x8901007 | same |
| Wi-Fi (QCNFA765) | 0x11087fff (2025-07-16) | same |
| EC fan-loop parameters (0xFE700B90 to 0xB98) | `00 00 00 00 50 00 00 64 03` | same |
| Steam client | 1791918634 | 1788652215 |

Not readable from software: battery gauge firmware version, controller-board MCU firmware, display bridge firmware.

## Hardware differences

| | Main unit | Second unit |
|---|---|---|
| Battery pack part (EC 0xFE700A40) | **F7G-T0A** | **F7G-M0A** |
| Battery model_name (BTMN, EC 0xFE700A60) | **ATC** | **VDL-M** |
| Battery serial prefix (BTSS, EC 0xFE700A70) | SEBN… | SEDP… |
| Design / full capacity | 6490 / 6722 mAh (103 %) | 6470 / 6894 mAh (106 %) |
| Design voltage | 7740 mV | 7760 mV |
| Cell voltages (EC 0xFE700A00, 2 x u16 mV) | 4155 / 4155 (rest, 79 %) | 4182 / 4173 (charging, 53 %) |
| EC 0xFE700A20 to 0xA2C | `01 00 0f 00 00 00 64 5c 31 00 54 30 41` | `00 00 05 00 00 00 21 20 31 00 4d 30 41` |
| EC 0xFE700AA0 to 0xAA8 | `00 04 12 31 41 41` | `00 07 10 1f 44 31 31 30 44` |
| RAM (16 GB LPDDR5-6400) | SK hynix H58G66BK8HX128 | Samsung K3KL3L30CM-DGCT |
| SSD | Phison ESMP001TKB6QC3-E27TS (ERFM20.0) | Kingston OM3SGP4512K2-A00 (SDW02105) |
| Serial prefix | FYZZ62 | FVZZ61 |
| APU | AMD Custom APU 0932, stepping 0 | same |
| Panel EDID | VLV 0x3003 (ANX7530 bridge) | same |

Interpretation of the unlabeled battery bytes is a guess: 0xA26/0xA27 = `0x5c64` decodes as an SBS-style date 2026-03-04 on the main unit, while the second unit's `0x2021` decodes as 1996-01-01, which looks unset. The 0xAA0 block looks like a length-prefixed blob (4 vs 7 bytes) and may be gauge identification data.

The fan, its connector, and passive parts cannot be compared from software.
