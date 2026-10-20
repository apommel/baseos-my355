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
`wifi_bt_vbat`; what cutting them saves over the soft block is not measured yet.

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
`my355 charge` (charging while off) always sets 1500 mA ([U-Boot](uboot.md)).
