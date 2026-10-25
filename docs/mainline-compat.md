# Mainline compatibility list

What stock-built software (NextUI, its daemons, its paks) touches on the
running kernel, and what a mainline kernel has to provide for it to keep
working unmodified. Where the mainline build stands against it is under
[Status](#status) at the end.

## How this was gathered

- **Trace.** On 2026-10-25, a static aarch64 `strace` 6.10 was attached
  under BaseOS 1.3.0, stock kernel. It followed the NextUI `launch.sh` with
  `-f`, plus the daemons it had already started. It recorded opens, execs,
  ioctls, file checks, writes, sockets and mounts. About 7 minutes, 3 217
  execs.
- **Snapshot.** The open files of the daemons that started before the attach.
- **Static scan.** The `my355` scripts, plus strings in `libmsettings.so` and
  the `.system/my355/bin` binaries.

- **Second trace.** The same attach, about 3 minutes: sleep and wake, HDMI
  plug and unplug, rumble.
- **Source.** NextUI `88df5245`, `workspace/my355`: `platform/`,
  `libmsettings/` and `keymon/`.

Exercised: menus, Settings (volume, brightness, contrast, saturation), WiFi
and Bluetooth off/on, sleep and wake, HDMI hotplug, GBA (`minarch.elf`), N64
(`mupen64plus`), and the Tools paks (Battery, Clock, Files, Grout, Input, RA
Explorer, ScrapeGoat, Status LED, Game Tracker, Base Jumper, Developer,
NextCommander).

**Not covered:**
- Rumble never fired in either trace. It is taken from source:
  `PLAT_setRumble` writes `0` or `1` to `gpio20`.
- PPSSPP, DraStic, Flycast and PortMaster aren't installed on this card.
  Dolphin is set aside for now.
- The boot-time part of `launch.sh` is taken from its source.

## Strategy, in order of preference

1. **Match stock's names in the device tree or in a driver.** This is free at
   run time, and nothing stock can tell the difference.
2. **A small compatibility driver**, when stock reads an attribute that only
   the vendor kernel has.
3. **A wrapper for a command BaseOS already ships.** `modetest` and `amixer`
   come from our rootfs, not from the card.
4. **An `LD_PRELOAD` path remapper**, as the last resort, for fixed
   `/sys/class/gpio` numbers and the like. It only reaches dynamically linked
   programs, and it runs inside every emulator.

Anything under "BaseOS-owned" below is ours to change. Only stock-built code
constrains the design.

## Stock-built dependencies

| What | Who | Stock kernel | Mainline gap | Fix |
|---|---|---|---|---|
| `/dev/mali0`: kbase ioctls, dma-buf | NextUI, every SDL/GLES program | kbase g18p0 | ROCKNIX `mali_kbase` gives `/dev/mali0` | Test the g13p0 and g29p1 blobs against it |
| `/dev/dri/card0`: legacy KMS (`SETCRTC`, `PAGE_FLIP`, dumb buffers, PRIME), `SET_MASTER` | NextUI, minarch, tools | rockchip-drm is `card0` | Panfrost also registers a `card` node, so `card0` must stay rockchip-drm | Probe order, or build Panfrost as a module loaded later |
| `/sys/class/drm/card0-HDMI-A-1/status` | libmsettings, keymon, NextUI | present | Same name as long as rockchip-drm is `card0` | as above |
| `modetest -M rockchip -w 179:contrast:N`, `179:saturation:N` | libmsettings `SetRawContrast`, `SetRawSaturation` | vendor VOP2 properties on connector 179, `DSI-1` (`HDMI-A-1` is 164) | zlyme `1013` adds legacy TV properties with the same names, on the connectors, but under different object IDs | `modetest` wrapper that maps 179 to the `DSI-1` connector |
| `/dev/i2c-0`, `I2C_SLAVE_FORCE 0x20`, writes to `RK817_DDAC_VOLL`/`VOLR` (`0x31`/`0x32`) | libmsettings `SetVolume`, speaker path | Goes past the driver because `SPK Volume` stops at -37.5 dB. Written on every volume change after `Playback Path`, so the bottom levels reach -57 dB | Needs `CONFIG_I2C_CHARDEV` and `i2c0` as bus 0. If it fails, only the lowest volume levels get louder, down to the -37.5 dB floor | Keep the bus alias. Better: a mainline volume control with the codec's full range, then the write is harmless |
| ALSA cards found by substring in `/proc/asound/cards`: `rockchiprk817` (codec), `rockchiphdmi` (HDMI), `USB-Audio` | libmsettings | `rockchip-rk817`, `rockchip,hdmi` | zlyme names the codec `rk817_ext`; the mainline HDMI card name differs too | Card names that give these IDs: `simple-audio-card,name = "rockchip-rk817"`, and the same for HDMI |
| Mixer controls by name through tinyalsa: `Playback Path` (enum `OFF`, `HP`, `SPK`), `Speaker Switch`, `Headphone Switch`, `SPK Volume` (0–100); plus `tinymix set 1 SPK` in `launch.sh` | libmsettings `SetVolume`, `launch.sh` | vendor rk817 codec | `Playback Path` and `SPK Volume` are vendor-only. A missing control is skipped silently, so the symptom is no sound or no volume control, not a crash | Codec patch adding the stock controls on top of mainline routing |
| `/sys/class/gpio/gpio150/value`, exported by `launch.sh`, `0` = jack in | libmsettings, keymon (headphone detect) | legacy GPIO number 150 = GPIO4_C6 | Mainline numbers GPIOs dynamically from 512, and `hp-det-gpios` holds the line, so it can't be exported | Remapper or a compatibility attribute; keep jack detection in the kernel |
| `/sys/class/gpio/gpio20/value`, `0`/`1` only (on/off, no strength; skipped while on HDMI) | NextUI `PLAT_setRumble`, `launch.sh` | GPIO 20 = GPIO0_C4 | Same numbering problem, and zlyme puts the motor on `pwm5` through its gamepad driver | Keep the motor a GPIO in the DT, and remap; or a compatibility attribute that drives the PWM |
| `/sys/class/pwm/pwmchip0/pwm0/{period,duty_cycle,enable}` after unbinding `pwm-backlight`, period 1 250 000 ns, plus parsing `/sys/kernel/debug/pwm` | `launch.sh`, libmsettings `SetRawBrightness` | backlight = pwmchip0 | The backlight is `pwm4`; mainline `pwmchipN` follows probe order, and debugfs output differs. If the debugfs parse fails, `launch.sh` just skips the carry-over | Make the backlight PWM probe first, or remap |
| `/sys/class/backlight/backlight/bl_power` | NextUI | present | Same if the DT node is named `backlight` | DT |
| `/sys/devices/platform/hall-mh248/hallvalue` (polled about 30 times a second) | NextUI, libmsettings, `suspend` | vendor hall driver attribute | Mainline has a `gpio-keys` `SW_LID` instead | A small `hall-mh248` platform driver exposing `hallvalue` |
| `mv /dev/input/event1 /dev/input/event1.disabled` | `launch.sh` | event1 = `hall wake key` | Mainline numbering would hide whichever device lands at event1 | Keep the hall input at event1 |
| keymon opens **`event0` only**, plus USB input nodes, for volume and power keys (`CODE_POWER` 102, `CODE_PLUS` 128, `CODE_MINUS` 129). It skips `adc-keys` because it duplicates `event0` | keymon | event0 = `gpio-keys-polled` | Whatever lands at event0 on mainline is what keymon reads | event0 must be a `gpio-keys` device with stock's key codes. The stock DTB in `boot.img` is the reference |
| The rest of input goes through SDL joystick button indices: `JOY_B` 0, `JOY_A` 1, `JOY_Y` 2, `JOY_X` 3, `L1` 4, `R1` 5, `SELECT` 6, `START` 7, `MENU` 8, `L3` 9, `R3` 10. Keyboard codes from `gpio-keys-polled` are ignored | NextUI, minarch (`platform.h`) | `MIYOO Player1` | SDL numbers buttons in key-code order, so the indices only hold if the key set is identical | Present the same device, below |
| `MIYOO Player1`: bus 3 (USB), `045e:028e` version `0114` (Xbox 360 pad IDs), keys `BTN_SOUTH`, `EAST`, `NORTH`, `WEST`, `TL`, `TR`, `SELECT`, `START`, `MODE`, `THUMBL`, `THUMBR`, axes `ABS_X`, `Y`, `Z`, `RX`, `RY`, `RZ`, `HAT0X`, `HAT0Y`, no force feedback. Created by `miyoo_inputd` from `/dev/ttyS1` (stick MCU), `/dev/miyooio`, `/sys/class/miyooio_chr_dev/joy_type`, through `/dev/uinput` | `launch.sh` starts it | vendor `miyooio` character driver | No `miyooio` on mainline | zlyme's gamepad driver presenting exactly this identity (name, bus, IDs, keys, axes and their ranges). Or a `miyooio` compatibility driver so the stock daemon runs. The driver is less code to carry, but `miyoo_inputd` then has to fail harmlessly |
| Other input numbering: event1 `hall wake key`, event2 `rk805 pwrkey`, event3 `adc-keys`, event4 `hdmi_cec_key`, event5 `MIYOO Player1` | `launch.sh` (event1), SDL's enumeration | registration order | Only event0 and event1 are named by number | Keep event0 and event1 fixed; the others can float |
| `/sys/class/power_supply/{battery/capacity,battery/status,ac/online,usb/online}` | batmon, NextUI, Battery pak | `battery`, `ac`, `usb` | Mainline uses `rk817-battery` and `rk817-charger`; zlyme renames them to `battery` and `charger` | Rename to `battery`; split or rename the charger into `ac` and `usb` |
| LEDs `work` and `charger`: `brightness`, `max_brightness`, `trigger` set to `battery-charging`, `default-on`, `heartbeat` | Status LED pak | present | zlyme labels them `green:power` and `red:status`; `battery-charging` only exists if the supply is named `battery` | DT labels `work` and `charger` |
| `/sys/class/udc/*/state` | NextUI, tools | `fcc00000.dwc3` | `fcc00000.usb` on mainline; read by listing the directory | Probably fine; check a literal use |
| cpufreq `policy0`: governors `schedutil`/`performance`/`conservative`, `scaling_{min,max}_freq`, `scaling_setspeed`, `scaling_available_frequencies`; `cpu1`–`cpu3/online` | `governor.sh`, Settings | — | Standard interfaces, but different frequency steps; `second_max` and `mid` are picked by position | Keep stock's frequency list (no 1992 MHz) |
| `/sys/class/devfreq/fde60000.gpu/{governor,min_freq}`, `/sys/class/devfreq/dmc/governor` | `GC.pak`, tools | present | kbase on mainline keeps `fde60000.gpu`; check the name zlyme's `rk3568-dmc` registers | Check |
| Sleep: pre-sleep hooks, `killall -STOP` keymon, batmon and audiomon, stop `wpa_supplicant`, write `deep` to `/sys/power/mem_sleep`, then `mem` to `/sys/power/state` with up to 5 attempts, then resume, `-CONT` the daemons and restart WiFi. While asleep, the lid is read from `hallvalue` | `suspend` (run by NextUI) | vendor suspend; worked even under strace | Needs zlyme's deep-suspend work, and `deep` must be listed in `mem_sleep` | Port zlyme's BL31 suspend |
| HDMI: polls `/sys/class/drm/card0-HDMI-A-1/status`. On connect, sound moves to the `rockchiphdmi` card, the panel goes to brightness 0, and rumble is skipped | NextUI, keymon, libmsettings | — | The connector name holds if rockchip-drm is `card0`; the card name needs the DT | as above |
| `insmod /system/lib/modules/RTL8189FU.ko`, `insmod /lib/modules/rtk_btusb.ko` | `wifi_init.sh`, `bt_init.sh` | vendor modules | Fail harmlessly on mainline | Load our own modules first |
| `wlan0`, nl80211, `/dev/rfkill` (`rfkill.elf`), `iw`, `wpa_cli`, `bluetoothctl`, `hciconfig`, `hcitool`, `bluealsa` | NextUI, radio scripts | — | Standard interfaces; the 8733bu driver names its interface `wlan0` | Keep `wlan0` |
| `/dev/fb0` (`cat /dev/zero > /dev/fb0`) | NextUI, `shutdown` | DRM fbdev emulation | `CONFIG_DRM_FBDEV_EMULATION=y` | config |
| `/dev/rtc0` (`hwclock`) | Clock, Settings | RK817 RTC | same | — |
| `mkswap` and `swapon` on `/mnt/UDISK/n64_swap` | N64.pak | — | `CONFIG_SWAP=y`; the path must exist | config, rootfs |
| `/dev/uinput`, `/dev/input/js0`, `/dev/shm`, `/dev/snd/*` | various | — | standard | — |

## BaseOS-owned (ours to change)

- `/sys/class/rkwifi/wifi_power` and `/sys/bus/usb/devices/2-1`, used by
  `wifibt-power`. Mainline would use zlyme's `rtl8733bu-power` module or
  rfkill.
- `S36load_wifi_modules`, `S40bluetooth`, `S41dhcpcd`, `wifibtd`.
- The rootfs copies of `modetest` and `amixer`, which is where the wrappers
  would go.

## Open questions

1. **Which kbase do the blobs accept?** ROCKNIX's `mali_kbase` at the pinned
   commit is r54p2, UK 11.46. Stock's kbase is UK 11.38, and kbase accepts
   older minor versions, so g13p0 should negotiate. Still to confirm on
   hardware, for g13p0 and g29p1.
2. **What does `/dev/miyooio` do?** That decides between keeping
   `miyoo_inputd` and a kernel driver named `MIYOO Player1`. Also record the
   axis ranges of `MIYOO Player1`, since SDL mappings depend on them.
3. ~~What are stock's input key codes?~~ Read from the stock DTB and copied
   into `tools/kernel/dts/rk3566-miyoo-flip.dts`: the `gpio-keys-polled` and
   `hall-mh248` nodes, the LEDs and the backlight table.
4. **Does any pak or tool name `fcc00000.dwc3` literally?**
5. **What do Dolphin and any standalone paks installed later touch?** Trace
   them when they're on the card.

## Status

`./build-kernel.sh` builds Linux 7.2.10: `tools/kernel` holds the patches,
ROCKNIX's panel driver, the device tree and the config fragment, and the
build adds `mali_kbase` as a module. `MY355_KERNEL=mainline` puts the modules
in the rootfs and the kernel in the boot FIT, and rcS loads `mali_kbase`.

It boots to BaseOS with adb, checked on 2026-11-04. These match stock:

- `mmcblk1` for the boot slot, `mmcblk2` for the second slot
- event0 `gpio-keys-polled`, stock's pins and codes
- LEDs `work` and `charger`, supplies `battery` and `usb`
- `pwmchip0` (the backlight) and `backlight`
- GPIO chips at 0, 32, 64, 96 and 128, so `gpio150` and `gpio20` are free
- `MIYOO Player1`: name, IDs, keys, axes and ranges, from a kernel driver
- ALSA `rockchiprk817` as card 0, `rockchiphdmi` as card 1
- the reboot modes, so a shutdown with the charger in restarts into charge mode
- `/dev/mali0` (r54p2), `card0` with `DSI-1` and `HDMI-A-1`

Different from stock, found on the first boots:

- **SD speed.** With UHS, tuning fails on the boot slot (`-5`), the card then
  stops answering (`-110`) and the root never mounts. Keeping the card rails
  on (`regulator-boot-on`, as stock) and 36 tuning steps did not help. The slot
  runs at high speed, 50 MHz and 3.3 V. The vendor kernel does SDR104 on the
  same card.
- **adb.** Bound with no data cable attached, the USB2 PHY stays idle and dwc3
  fails EP0 (`failed to enable ep0out`), as zlyme found in its Phase 12D
  research. `peripheral` mode didn't help. `usb-gadget-adb` waits for the OTG
  PHY's extcon to report SDP or CDP, then binds. The port stays `otg`.
  Booted without the cable, the port is suspended, and charger detection run
  in that state reports a DCP, so a computer plugged in later was never bound.
  The PHY driver now powers the port on before detecting.
- **GPU rail.** `mali_kbase` disables `vdd_gpu` on runtime suspend without
  having enabled it, and the unused-regulator cleanup then cut the rail. It
  is always-on again, as in zlyme.
- **HDMI sound.** No `rockchiphdmi` card: dw-hdmi only registers its audio
  codec with `DRM_DW_HDMI_I2S_AUDIO` built in, and it was a module. Built in
  now.
- **Black screen under NextUI.** `launch.sh` unbinds `pwm-backlight` to drive
  the PWM itself. Mainline links the panel to its backlight, so the unbind took
  the panel, the DSI host and all of DRM with it. The link is patched out.
- **Card order.** HDMI probed first and became card 0, the default device
  NextUI's sound goes to. A `sound` alias now sets the number, as stock has it.
- **Restart.** Mainline restarts the RK817 by PMIC reset, which power-cycles
  the SoC and clears the reboot-mode flag. A shutdown with the charger in then
  booted the system again. It restarts through PSCI now, as the vendor
  kernel does, and the device tree has the stock reboot modes.
- **Boot time.** The framebuffer console's first modeset held kernel init for
  1.2 s, mostly the panel's power-up waits. The console is off, as on the
  vendor kernel, and the waits are shortened as on the vendor path. Then
  dbus-daemon blocked 1 s on the crng, ready only at ~3 s: mainline leaves the
  RK3566 TRNG off, as it fails quality tests. `rcS` now credits the seed saved
  at shutdown (`seedrng`) before starting dbus.
- **The gamepad.** Stock's `miyoo_inputd` builds `MIYOO Player1` through
  uinput, from the vendor `/dev/miyooio` (the `gpio-keys-polled` pins) and the
  stick MCU on `ttyS1`. The `miyoo-player1` driver presents the same device:
  it listens to event0's keys, which stay as on stock for keymon, and reads the
  MCU as a serdev, so there is no `/dev/ttyS1`. It registers last, after every
  other input device. `miyoo_inputd` is a shim that hands the driver
  `/userdata/joypad.config` and `joypad_right.config` (sysfs
  `calibration_left`, `calibration_right`, same format) and idles. Turbo
  (`/tmp/miyoo_inputd/turbo_*`) is not carried over, and Joe's Calibrage, which
  reads `/dev/ttyS1`, would need the driver's `raw` attribute instead.
- **Backlight hand-over.** `launch.sh` reads the duty from
  `/sys/kernel/debug/pwm` in the vendor format. Mainline's differs, so the
  panel stays dark until keymon sets the brightness.
- **event1 is `rk805 pwrkey`.** On stock it is `hall wake key`, and
  `launch.sh` moves `event1` aside, so under NextUI it would disable the power
  key. The hall driver has to register before the power key.
- **event0 IDs.** Bus `0019`, `0001:0001`, where stock has `045e:028e`.

Still to do:

- the `hall-mh248` driver, and input ordering
- the codec's stock controls
- the `modetest` connector id
- SD UHS
- WiFi power, suspend, DMC
- the Panfrost switch
