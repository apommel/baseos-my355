# Power

What the Flip draws on battery, where it goes, and what BaseOS can change.
Measured 2026-10-20 on battery from `current_now` × `voltage_now`, with a probe
that runs detached and changes one thing per point. The gauge refreshes
`current_now` about every 5 s, so a 20 s point holds 3–4 real readings and
differences under ~100 mW are noise.

## Idle, screen on

NextUI or the Developer Pak in front, WiFi associated, brightness at ~2% duty:
**~2.44 W** (≈600 mA), CPU 97% idle at 408 MHz.

| change | mW |
|---|---|
| backlight off | −140 |
| backlight at 50% duty | +600 |
| `miyoo_inputd` stopped (DDR falls to 324 MHz, no stick wake-ups) | −190 |
| `miyoo_inputd` stopped, DDR held at 1056 MHz | ≈0 |
| `wlan0` down | −310 |

About 1.9 W is left with all of those off: SoC, display pipeline, panel and
rails. That is why CPU undervolting (`feat/undervolting`) moved little at idle —
`vdd_cpu` is not where idle power goes.

## The DDR touch boost — removed

The vendor DMC driver (`rockchip_dmc.c`) registers an input handler that holds
the DDR at `boost_rate` for 500 ms after any `EV_KEY` or `EV_ABS` event.
`miyoo_inputd`'s virtual pad (`MIYOO Player1`) re-reports stick noise about 87
times a second at rest, so the boost never lapsed: **1056 MHz for 383 of 384 s
since boot, at 2% load**. Pausing `miyoo_inputd` dropped the DDR to 324 MHz
within a second.

Holding 1056 against 324 MHz cost 80 mW in one back-to-back pair and ~180 mW in
another. The wake-ups themselves cost nothing measurable; the rate does.

`rkbootimg.drop_dmc_touchboost` removes `SYS_STATUS_BOOST` from
`dmc/system-status-level`, so `boost_rate` stays 0 and
`rockchip_dmcfreq_boost_init()` registers no handler. Rate selection is then
the driver's load-based path (`auto-freq-en`, upthreshold 40%, 324 MHz floor)
plus the VOP's bandwidth requests (`vop-bw-dmc-freq`), both unchanged.

## WiFi and Bluetooth

One Realtek RTL8733BU on USB (`2-1`) carries both. WiFi runs at the driver's
deepest station power save already (`LPS mode: MAX`); `rtw_lps_level` is 0
(`LPS_NORMAL`), with clock- and power-gated levels left alone because the link
is already weak. NextUI's WiFi and BT off are rfkill soft blocks (`wifi_init.sh`,
`bt_init.sh`), which leave the chip powered and enumerated. The vendor
`wlan-platdata` driver exposes `/sys/class/rkwifi/wifi_power` and
`wifi_bt_vbat`; writing 0 to both drops the chip off USB, and writing 1 brings
it back (`wifi_power` reads 0 whatever the state, so its read-back means
nothing). Developer Pak in front, BT never bound, two runs agreeing within
20 mW:

| WiFi | mW |
|---|---|
| on, associated | 2511 |
| NextUI's off (`wifi_init.sh stop`: rfkill, `wpa_supplicant` and `dhcpcd` stopped) | 2356 (−155) |
| the same, plus the chip's power cut | 2033 (−478) |

So **off is not off**: the powered, enumerated chip costs ~320 mW more than
cutting it.

### Cutting the chip when both are off

`wifibt-power want|release wifi|bt` holds the two intents and is the only thing
that touches the switch: off when WiFi is released and Bluetooth is not wanted,
on as soon as either is wanted. It decides from whether the chip is on the USB
bus (`2-1`), and writes the switches only to change them. A `flock` serialises
callers, because `launch.sh` starts WiFi and Bluetooth in parallel.

| | wanted | released |
|---|---|---|
| WiFi | `S36load_wifi_modules start`, before `wifi_init.sh` waits for `wlan0` | `S36load_wifi_modules stop` |
| Bluetooth | `rtk_btusb` loading, or the BT rfkill switch unblocked (`wifibtd`) | the BT rfkill switch blocked (`wifibtd`) |

Defaults: WiFi wanted, Bluetooth not. A frontend that never calls `S36` stop
never loses the chip; and Bluetooth needs no default, because of the rule
below.

Bluetooth is the hard side. `bt_init.sh start` waits up to 7 s for `hci0`
*before* it calls `S40bluetooth`, and `bt_init.sh stop` calls nothing of ours, so
no hook is early enough. What it does do is `insmod rtk_btusb` whenever `lsmod`
lacks it. Hence the rule: **the chip is only cut once `rtk_btusb` is unloaded**,
so the next Bluetooth start always loads it, and `wifibtd` (`src/wifibtd.c`)
turns that module's `add` uevent into power. If the module will not unload in
2 s, the chip stays on and the log says so. `wifibtd` also reads `/dev/rfkill`
for the Bluetooth switch, and `rcS` respawns it.

A Bluetooth block is only believed if it still holds 2 s later. `hci0`
registers into the global Bluetooth state, which the last `bt_init.sh stop` left
blocked, and `bt_init.sh` only unblocks it 0.5 s after its `insmod`: taken at
its word, that block cut the chip in the middle of the start it belonged to.
Waiting also keeps a quick off-and-on from cycling the chip.

A cut never outlives a boot: the kernel powers the chip at probe, and it
enumerates at ~1.7 s whatever state it was left in.

Exercised on the device through NextUI's own `wifi_init.sh` and `bt_init.sh`:
every on/off order of the two, each with exactly one power change where one is
due and none elsewhere, and both radios working in every state.

One race is closed by hand: `launch.sh` can release WiFi just after
`bt_init.sh` loaded `rtk_btusb` and before `wifibtd` saw it, and the cut then
unloads it. `want bt` therefore reloads the module when it is missing.

WiFi after a sleep: NextUI's `suspend` runs `wifi_init.sh stop`, which kills
`wpa_supplicant` last, just before the freeze, so on wake it can still be a
zombie until init reaps it (about once a second). `wifi_init.sh start` checks
`pidof wpa_supplicant`, took the zombie for a running one and started none:
`wlan0` came up with nothing to scan, twice in a row. `S36` start now waits, at
most 2 s, while a `wpa_supplicant` zombie exists.

`tests/test-wifibt-power.sh` covers the decisions offline. spruceOS's own WiFi
and Bluetooth scripts have not been checked against this.

## The battery gauge

- **Capacity is never learned.** The RK817 driver in this kernel writes
  `NEW_FCC` only as `design_capacity` or a clamp to `design_qmax`; there is no
  runtime FCC update, and the PMIC on the test unit still holds 3000 mAh.
  `my355 fg` preserves whatever is there ([U-Boot](uboot.md)).
- `power_off_thresd` is 3000 mV against an `ocv_table` whose 0% is 3378 mV, and
  `bat_res` is a generic 100 mΩ. Both feed the driver's end-of-discharge
  algorithm.

## Charging

The tree allows 2500 mA input and 2500 mA charge at 4.2 V. The kernel takes
1500 mA input on a CDP (a computer port) and `max_input_current` on a DCP.
`my355 charge` (charging while off) cannot tell the port apart and sets 2500 mA,
with the 4.5 V input floor backing it off on a source that sags ([U-Boot](uboot.md)).
