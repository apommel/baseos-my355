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
and Bluetooth off/on, Bluetooth audio and its reconnect after a deep sleep,
sleep and wake (work LED off while asleep), charge mode on a shutdown with
the charger in, HDMI hotplug, GBA (`minarch.elf`), N64
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

Mainline's own interface is the base, and stock's is a layer on top that
forwards to it: mainline tools keep working, and the stock view stays thin.
The layer is in the kernel wherever stock software reaches the kernel
directly. Stock's name replaces mainline's only where there can be just one,
such as a card id, a supply name or an event number. Where mainline would
claim a resource that stock software drives itself, such as the headphone
detect pin, userspace keeps it.

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
| `/dev/mali0`: kbase ioctls, dma-buf | NextUI, every SDL/GLES program | kbase g18p0 | ROCKNIX `mali_kbase` gives `/dev/mali0` | Done: libmali g29p1 on it, or Mesa with `gpu=panfrost` |
| `/dev/dri/card0`: legacy KMS (`SETCRTC`, `PAGE_FLIP`, dumb buffers, PRIME), `SET_MASTER` | NextUI, minarch, tools | rockchip-drm is `card0` | Panfrost also registers a `card` node, so `card0` must stay rockchip-drm | Done: Panfrost is a module, loaded after rockchip-drm |
| `/sys/class/drm/card0-HDMI-A-1/status` | libmsettings, keymon, NextUI | present | Same name as long as rockchip-drm is `card0` | as above |
| `modetest -M rockchip -w 179:contrast:N`, `179:saturation:N` | libmsettings `SetRawContrast`, `SetRawSaturation` | vendor VOP2 properties on connector 179, `DSI-1` (`HDMI-A-1` is 164) | zlyme `1013` (our `0040`) adds the TV properties with the same names and range, under other object IDs (`DSI-1` is 59). Setting them needs DRM master, which NextUI holds; the vendor kernel skips the check (`DRM_IGNORE_IOTCL_PERMIT`) | Done: a `modetest` wrapper maps 179 and 164 by `connector_id`, and `stock/0065` lets root set properties without master |
| `/dev/i2c-0`, `I2C_SLAVE_FORCE 0x20`, writes to `RK817_DDAC_VOLL`/`VOLR` (`0x31`/`0x32`) | libmsettings `SetVolume`, speaker path | Goes past the driver because `SPK Volume` stops at -37.5 dB. Written on every volume change after `Playback Path`, so the bottom levels reach -57 dB | Needs `CONFIG_I2C_CHARDEV` and `i2c0` as bus 0. If it fails, only the lowest volume levels get louder, down to the -37.5 dB floor | Keep the bus alias. Better: a mainline volume control with the codec's full range, then the write is harmless |
| ALSA cards found by substring in `/proc/asound/cards`: `rockchiprk817` (codec), `rockchiphdmi` (HDMI), `USB-Audio` | libmsettings | `rockchip-rk817`, `rockchip,hdmi` | zlyme names the codec `rk817_ext`; the mainline HDMI card name differs too | Card names that give these IDs: `simple-audio-card,name = "rockchip-rk817"`, and the same for HDMI |
| Mixer controls by name through tinyalsa: `Playback Path` (enum `OFF`, `HP`, `SPK`), `Speaker Switch`, `Headphone Switch`, `SPK Volume` (0–100); plus `tinymix set 1 SPK` in `launch.sh` | libmsettings `SetVolume`, `launch.sh` | vendor rk817 codec | `Playback Path` and `SPK Volume` are vendor-only. A missing control is skipped silently, so the symptom is no sound or no volume control, not a crash | Codec patch adding the stock controls on top of mainline routing |
| `/sys/class/gpio/gpio150/value`, exported by `launch.sh`, `0` = jack in | libmsettings, keymon (headphone detect) | legacy GPIO number 150 = GPIO4_C6 | Mainline numbers GPIOs dynamically from 512, and `hp-det-gpios` holds the line, so it can't be exported | Remapper or a compatibility attribute; keep jack detection in the kernel |
| `/sys/class/gpio/gpio20/value`, `0`/`1` only (on/off, no strength; skipped while on HDMI) | NextUI `PLAT_setRumble`, `launch.sh` | GPIO 20 = GPIO0_C4 | Same numbering problem, and zlyme puts the motor on `pwm5` through its gamepad driver | Keep the motor a GPIO in the DT, and remap; or a compatibility attribute that drives the PWM |
| `/sys/class/pwm/pwmchip0/pwm0/{period,duty_cycle,enable}` after unbinding `pwm-backlight`, period 1 250 000 ns, plus parsing `/sys/kernel/debug/pwm` | `launch.sh`, libmsettings `SetRawBrightness` | backlight = pwmchip0 | The backlight is `pwm4`; mainline `pwmchipN` follows probe order, and debugfs output differs. If the debugfs parse fails, `launch.sh` just skips the carry-over | Make the backlight PWM probe first, or remap |
| `/sys/class/backlight/backlight/bl_power` | NextUI | present | Same if the DT node is named `backlight` | DT |
| `/sys/devices/platform/hall-mh248/hallvalue` (polled about 30 times a second) | NextUI, libmsettings, `suspend` | vendor hall driver attribute | Mainline has a `gpio-keys` `SW_LID` instead | A small `hall-mh248` platform driver exposing `hallvalue` |
| `mv /dev/input/event1 /dev/input/event1.disabled` | `launch.sh` | event1 = `hall wake key` | Mainline numbering would hide whichever device lands at event1 | Keep the hall input at event1 |
| keymon opens **`event0` only**, plus USB input nodes, for volume and power keys (`CODE_POWER` 102, `CODE_PLUS` 128, `CODE_MINUS` 129). It skips `adc-keys` because it duplicates `event0` | keymon | event0 = `gpio-keys-polled` | Whatever lands at event0 on mainline is what keymon reads | event0 must be a `gpio-keys` device with stock's key codes. The stock DTB (in `mtd2`) is the reference |
| The rest of input goes through SDL joystick button indices: `JOY_B` 0, `JOY_A` 1, `JOY_Y` 2, `JOY_X` 3, `L1` 4, `R1` 5, `SELECT` 6, `START` 7, `MENU` 8, `L3` 9, `R3` 10. Keyboard codes from `gpio-keys-polled` are ignored | NextUI, minarch (`platform.h`) | `MIYOO Player1` | SDL numbers buttons in key-code order, so the indices only hold if the key set is identical | Present the same device, below |
| `MIYOO Player1`: bus 3 (USB), `045e:028e` version `0114` (Xbox 360 pad IDs), keys `BTN_SOUTH`, `EAST`, `NORTH`, `WEST`, `TL`, `TR`, `SELECT`, `START`, `MODE`, `THUMBL`, `THUMBR`, axes `ABS_X`, `Y`, `Z`, `RX`, `RY`, `RZ`, `HAT0X`, `HAT0Y`, no force feedback. Created by `miyoo_inputd` from `/dev/ttyS1` (stick MCU), `/dev/miyooio`, `/sys/class/miyooio_chr_dev/joy_type`, through `/dev/uinput` | `launch.sh` starts it | vendor `miyooio` character driver | No `miyooio` on mainline | zlyme's gamepad driver presenting exactly this identity (name, bus, IDs, keys, axes and their ranges). Or a `miyooio` compatibility driver so the stock daemon runs. The driver is less code to carry, but `miyoo_inputd` then has to fail harmlessly |
| Other input numbering: event1 `hall wake key`, event2 `rk805 pwrkey`, event3 `adc-keys`, event4 `hdmi_cec_key`, event5 `MIYOO Player1` | `launch.sh` (event1), SDL's enumeration | registration order | Only event0 and event1 are named by number | Keep event0 and event1 fixed; the others can float |
| `/sys/class/power_supply/{battery/capacity,battery/status,ac/online,usb/online}` | batmon, NextUI, Battery pak | `battery`, `ac`, `usb` | Mainline uses `rk817-battery` and `rk817-charger`; zlyme renames them to `battery` and `charger` | Rename to `battery`; split or rename the charger into `ac` and `usb` |
| LEDs `work` and `charger`: `brightness`, `max_brightness`, `trigger` set to `battery-charging`, `default-on`, `heartbeat` | Status LED pak | present | zlyme labels them `green:power` and `red:status`; `battery-charging` only exists if the supply is named `battery` | DT labels `work` and `charger` |
| `/sys/class/udc/*/state` | NextUI, tools | `fcc00000.dwc3` | `fcc00000.usb` on mainline; read by listing the directory | Probably fine; check a literal use |
| cpufreq `policy0`: governors `schedutil`/`performance`/`conservative`, `scaling_{min,max}_freq`, `scaling_setspeed`, `scaling_available_frequencies`; `cpu1`–`cpu3/online` | `governor.sh`, Settings | — | Standard interfaces, but different frequency steps; `second_max` and `mid` are picked by position | Stock's list, 1992 MHz included and not marked turbo, so `second_max` is 1800 MHz as on stock. Mainline stops at 1800, which made it 1608 |
| `/sys/class/devfreq/fde60000.gpu/{governor,min_freq}`, `/sys/class/devfreq/dmc/governor` | `GC.pak`, tools | present | kbase on mainline keeps `fde60000.gpu`; the DMC is `dmc`, named after its node | Node named `dmc`; the `performance` and `powersave` devfreq governors are built in |
| Sleep: pre-sleep hooks, `killall -STOP` keymon, batmon and audiomon, stop `wpa_supplicant`, write `deep` to `/sys/power/mem_sleep`, then `mem` to `/sys/power/state` with up to 5 attempts, then resume, `-CONT` the daemons and restart WiFi. While asleep, the lid is read from `hallvalue` | `suspend` (run by NextUI) | vendor suspend; worked even under strace | `deep` comes from PSCI; BL31 needs stock's sleep mode, which no mainline driver sends | `drivers/hardware/rockchip-pm-config.c` (after zlyme) sends it from stock's `rockchip,pm-rk3568` node; the RK817 rails take stock's sleep states, except `vccio_sd`, kept on since BaseOS runs from the card. USB host0's OHCI also claims the PHY's 480 MHz, as stock's `utmi` does: mainline's dtsi omits it, and suspend froze the SoC in that OHCI's callback. Lid and power key sleep and wake in NextUI (2026-10-26) |
| HDMI: polls `/sys/class/drm/card0-HDMI-A-1/status`. On connect, sound moves to the `rockchiphdmi` card, the panel goes to brightness 0, and rumble is skipped | NextUI, keymon, libmsettings | — | The connector name holds if rockchip-drm is `card0`; the card name needs the DT | as above |
| `insmod /system/lib/modules/RTL8189FU.ko`, `insmod /lib/modules/rtk_btusb.ko` | `wifi_init.sh`, `bt_init.sh` | vendor modules | Fail harmlessly on mainline | Load our own modules first |
| `wlan0`, nl80211, `/dev/rfkill` (`rfkill.elf`), `iw`, `wpa_cli`, `bluetoothctl`, `hciconfig`, `hcitool`, `bluealsa` | NextUI, radio scripts | — | Standard interfaces; the 8733bu driver names its interface `wlan0` | Keep `wlan0` |
| `/dev/fb0` (`cat /dev/zero > /dev/fb0`) | NextUI, `shutdown` | DRM fbdev emulation | `CONFIG_DRM_FBDEV_EMULATION=y` | config |
| `/dev/rtc0` (`hwclock`) | Clock, Settings | RK817 RTC | same | — |
| `mkswap` and `swapon` on `/mnt/UDISK/n64_swap` | N64.pak | — | `CONFIG_SWAP=y`; the path must exist | config, rootfs |
| `/dev/uinput`, `/dev/input/js0`, `/dev/shm`, `/dev/snd/*` | various | — | standard | — |

## BaseOS-owned (ours to change)

- `wifibt-power`, which writes `/sys/class/rkwifi/wifi_power` (also written by
  spruceOS, so stock-facing) and finds the chip by its USB ID, `0bda:b733`:
  it is `2-1` on the vendor kernel and `3-1` here.
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

`./build-kernel.sh` builds Linux 7.2.10: `tools/kernel` holds the device
tree, the config fragment, and the patches and drivers, each split in two.
`hardware/` makes the board work on mainline and could go upstream; `stock/`
is the vendor interface on top, BaseOS-only. The out-of-tree `mali_kbase`
and `8733bu` carry their own patches. The build adds both as modules. It is
the only kernel BaseOS builds since the vendor path was removed
([decisions](decisions.md)); the comparisons with "main" below are against
the last vendor-kernel build.

It boots to BaseOS with adb, checked on 2026-10-25. These match stock:

- `mmcblk1` for the boot slot, `mmcblk2` for the second slot
- event0 `gpio-keys-polled` with stock's codes for menu and volume
- event1 `hall wake key` and `hallvalue`, from a `hall-mh248` driver
- LEDs `work` and `charger`, supplies `battery` and `usb`
- `pwmchip0` (the backlight) and `backlight`
- GPIO chips at 0, 32, 64, 96 and 128, so `gpio150` and `gpio20` are free
- `MIYOO Player1`: name, IDs, keys, axes and ranges, from a kernel driver
- ALSA `rockchiprk817` as card 0, `rockchiphdmi` as card 1
- the codec's `Playback Path` and `SPK Volume`
- the reboot modes, so a shutdown with the charger in restarts into charge mode
- `/dev/mali0` (r54p2), `card0` with `DSI-1` and `HDMI-A-1`

Different from stock, found on the first boots:

- **SD speed.** With UHS, tuning failed on the boot slot (`-5`, all phases
  bad), the card then stopped answering (`-110`) and the root never mounted.
  The io-domains driver defers on the PMIC's regulators and is only retried
  at late_initcall, so the slot had switched to 1.8 V and tuned before
  vccio3's pads left 3.3 V mode; the core's retry power-cycles the card, which
  does not come back on this board. zlyme's first tuning fails the same way,
  and its retry works only because its card power is not wired. A known
  upstream race (Jonas Karlman on the rock-3b UHS series, 2024). An
  `io-domains-supply` on the slot makes fw_devlink probe it after the
  io-domains: SDR104 at 0.56 s, 64.6 MB/s (high speed: 22.5), and through
  lid sleep (2026-10-27). `rockchip,desired-num-phases = 36`, as on the
  vendor path, keeps tuning off the bad window's edge ([boot
  time](boot-time.md)).
- **Charge voltage.** Mainline programs the RK817's charge voltage straight
  from the battery node, which had 4.25 V; the vendor tree charges to 4.2 V
  and ends at 300 mA. The node now has the vendor's values and `ocv_table`
  end points (2026-10-27).
- **Restart at 1.8 V.** Shutdown left `vccio_sd` at 1.8 V, and a PSCI restart
  keeps the PMIC's rails: the preloader could not read the card and booted
  stock from NAND. The SD core now returns vqmmc to 3.3 V after the power-off,
  as the vendor kernel's `mmc_sd_shutdown()` does (`0045`). A PMIC restart
  would also fix it but loses the reboot-mode flag (*Restart*, below).
- **adb.** Bound with no data cable attached, the USB2 PHY stays idle and dwc3
  fails EP0 (`failed to enable ep0out`), as zlyme found in its Phase 12D
  research. `peripheral` mode didn't help. `usb-gadget-adb` waits for the OTG
  PHY's extcon to report SDP or CDP, then binds. The port stays `otg`.
  Booted without the cable, the port is suspended, and charger detection run
  in that state reports a DCP, so a computer plugged in later was never bound.
  The PHY driver now powers the port on before detecting. A replug often went
  unreported too: a bounce during detection marked VBUS as seen, so the SDP
  found afterwards was not a change and extcon stayed empty (zlyme saw the
  same, Phase 12D). The driver now records VBUS only with its report.
- **Charger LED.** `rk817_charger` notified only from its plug irqs, before
  charging starts or stops, and the `battery-charging` trigger reads status
  only on a notification: dark while charging, lit after unplugging. Its
  poll now notifies when the status changes, and the plug irqs run it again
  2 s later.
- **GPU rail.** `mali_kbase` disables `vdd_gpu` on runtime suspend without
  having enabled it, and the unused-regulator cleanup then cut the rail. It
  is always-on again, as in zlyme.
- **GPU drivers.** `gpu=` in `baseos.conf` picks `mali` (the default) or
  `panfrost`, read by `baseos-gpu` once the frontend card is mounted.
  `build-gpu.sh` builds both: Rockchip's newest G52 libmali (g29p1, from
  `libmali-next`) with its wrappers, hook and Vulkan ICD, and Mesa 26.2.5's
  Panfrost and PanVK in `/usr/lib/mesa`, mounted over libmali's names and
  `/usr/share/vulkan` for Panfrost. The Vulkan loader is Debian's.
  - g29p1's GBM allocates from `/dev/dma_heap/system`; the heaps are built in.
  - NextUI, minarch and nextval link `libmali.so.1` and `libmali_hook.so.1`,
    not `libEGL`, so Mesa's side has a `libmali.so.1` that pulls in its EGL,
    GLES and GBM, and a hook with only `mali_injected`.
  - NextUI asks for GLES 3.2, and Panfrost has 3.1 on the G52: its shaders
    are 3.0, so `MESA_GLES_VERSION_OVERRIDE=3.2`. The shader cache is on
    `/data`.
  - PanVK has the G52 behind `PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1`, set for
    the frontend, and gives Vulkan 1.0; libmali gives 1.3. Both have
    `VK_KHR_display`. libmali's Wayland and X11 layer is left out.

  Both run NextUI, minarch with shaders and N64 (2026-10-27). In game,
  Panfrost drew 2.92 W, as libmali.
- **HDMI sound.** No `rockchiphdmi` card: dw-hdmi only registers its audio
  codec with `DRM_DW_HDMI_I2S_AUDIO` built in, and it was a module. Built in
  now.
- **Black screen under NextUI.** `launch.sh` unbinds `pwm-backlight` to drive
  the PWM itself. Mainline links the panel to its backlight, so the unbind took
  the panel, the DSI host and all of DRM with it. The link is patched out.
- **Contrast and saturation.** NextUI's `modetest` writes reached the wrong
  object (mainline numbers `DSI-1` 59, not 179), then needed DRM master,
  which NextUI holds and the vendor kernel never checks. A `modetest` wrapper
  maps the ids and `stock/0065` lets root set properties. Any value off 50
  then blacked the panel, as zlyme found: its BCSH port (our `0040`) set the
  output mode to 0, the BSP's black. It is 3 now, with the BSP's BT.709 CSC.
  Both sliders work from Settings (2026-10-27).
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
  it polls the game buttons' GPIOs, takes menu from event0 and reads the MCU
  as a serdev, so there is no `/dev/ttyS1`. It registers last, after every
  other input device. `miyoo_inputd` is a shim that hands the driver
  `/userdata/joypad.config` and `joypad_right.config` (sysfs
  `calibration_left`, `calibration_right`, same format) and idles. Turbo
  (`/tmp/miyoo_inputd/turbo_*`) is not carried over, and Joe's Calibrage, which
  reads `/dev/ttyS1`, would need the driver's `raw` attribute instead.
- **Backlight hand-over.** `launch.sh` reads the duty from
  `/sys/kernel/debug/pwm` in the vendor format. Mainline's differs, so the
  panel stays dark until keymon sets the brightness. Left as it is: debugfs
  is not an interface, and NextUI is to stop unbinding the backlight.
- **Backlight table.** Stock's holds levels 1-38 at 7.8-15% duty, so NextUI
  unbinds `pwm-backlight` to reach 2%. Here a level is the duty in 255ths
  from 2% (levels 1-4 stay at 2%, where the panel still lights), the same as
  stock from 39 up. NextUI's raw values written to `brightness` then give the
  duty it writes to the PWM; on the vendor kernel they come out brighter
  below 39. Stock-built software asking for 1-38 gets a dimmer panel.
- **event0 has three keys.** On stock it also types every game button as a
  keyboard key, so anything reading both devices saw each press twice. It
  keeps menu and volume for keymon, and the game buttons are only on
  `MIYOO Player1`. Menu is on both, as keymon needs it.
- **The lid.** `hall-mh248` probes before the PMIC's power key, so it is
  event1 as on stock, and `launch.sh` moves it aside instead of the power key.
  Its `KEY_POWER` comes on every lid move: stock's comes on close with the
  screen on and on open with it off, which needs the vendor fb notifier. The
  same device reports `SW_LID`, as mainline lid switches do.
- **The gamepad's name stays `MIYOO Player1`.** SDL's controller GUID carries
  a checksum of the name since SDL 2.26, and RetroArch-style autoconfig
  matches on it, so a more standard name would lose existing mappings.
- **Codec controls.** Mainline's codec has `Playback Mux` (`HP`, `SPK`),
  which nothing stock sets, and it starts on `HP`, so the speaker was silent.
  A patch adds the vendor's `Playback Path` (all eleven entries) and
  `SPK Volume` first, as views of the mainline controls: `Playback Mux`, the
  card's `Speaker Switch` and `Headphone Switch` pin switches, and
  `Master Playback Volume`. `Capture MIC Path` is left out: nothing stock-built
  sets it. The
  `SPK` entries pick the speaker, the `HP` ones the headphones. `SPK_HP` and
  `RING_SPK_HP` play on the speaker only, as the two outputs share a pin, and
  `BT` is silent. Read back, `Playback Path` is `OFF`, `SPK` or `HP`.
  `Resume Path` is left out. rcS sets `Playback Mux` to `SPK` and turns the
  headphones off at boot, where the vendor driver starts on `OFF`.
- **WiFi and Bluetooth.** The RTL8733BU's WiFi has no mainline driver: it
  is Realtek's `8733bu`, built out of tree at zlyme's pin with zlyme's seven
  patches (ROCKNIX's crash and suspend fixes, one `wlan0`, WPA3, the 7.2
  port) and its module options. Bluetooth is mainline's `btusb` and `btrtl`
  (patch 0010), with stock's firmware linked under the names `btrtl` asks
  for. The chip's power is a `vcc_wifi` regulator on GPIO0_A0. Stock's
  layer:
  - `/sys/class/rkwifi/wifi_power`, from `drivers/stock/rkwifi.c`, matched on
    stock's `wlan-platdata` node and switching that regulator;
  - `/lib/modules/rtk_btusb.ko`, the module `bt_init.sh` insmods: a
    stand-in that loads `8733bu` then `btusb`, since `btusb` first resets
    the chip and drops `wlan0`, and whose loading is what tells `wifibtd`
    to power the chip;
  - `S36load_wifi_modules` loads `8733bu`, where `wifi_init.sh`'s vendor
    insmod fails.
  Each radio's on/off is its driver's rfkill, which NextUI's `rfkill.elf`
  already targets. zlyme's `rtl8733bu-power`, its own pair of rfkills
  cutting the chip, is left out: BaseOS's `wifibt-power` already decides
  that. Its finding that the cut for suspend has to come in the late phase
  is for the suspend work. `wireless-regdb` is in the rootfs.
- **event0 IDs.** Bus `0019`, `0001:0001`, where stock has `045e:028e`.
- **CPU idle.** Mainline's rk356x has no idle states, so an idle core only
  ran WFI. The BSP's PSCI `cpu-sleep` is added (Chris Morgan's patch, via
  zlyme), which he measured at about 0.2 W at idle on an RG353P.
- **Battery readings.** The mainline gauge has `current_avg` and
  `voltage_avg`, not `current_now` and `voltage_now`. Nothing stock reads
  them; [power](power.md)'s method uses the averages here.

Against main, 2026-10-26, warm reboots and gambatte on battery:

| | mainline | main |
|---|---|---|
| U-Boot hands off | 0.82 s | 0.94 s |
| `Run /init` | 1.35 s, 1.40 s at SDR104 | 1.83 s |
| frontend hand-off | 1.65 s, 1.64 s at SDR104 | 1.99 s |
| `nextui.elf` start | 2.52 s, 2.32–2.34 s at SDR104 | 2.40 s |
| Game Boy, 408 MHz most of the time | 3.30 W, 3.38 W with `cpu-sleep` | 2.70 W |
| the same, WiFi power save as stock | 2.92–3.02 W | |
| the same, DMC | 2.92 W | |
| the same, one session, both on this branch (2026-10-27) | 2.77–2.97 W | 2.93 W |

Mainline printk starts at kernel entry, not power-on, so U-Boot's hand-off
is added. The hand-off to `nextui.elf` takes 0.87 s, against 0.42 s on main:
`launch.sh`'s first `nextval.elf` takes 0.72 s at boot (0.03 s warm, 0.26 s
cold alone), mapping `libmali` (18 MB) and SDL from the card while keymon,
batmon and audiomon load theirs. The card reads 22.5 MB/s at high speed,
against 63 MB/s at SDR104 on main. At SDR104 (64.6 MB/s, 2026-10-27) the
root mounts ~60 ms later, after the io-domains, and `nextui.elf` starts
1.50–1.52 s after kernel entry, against 1.70 s.

The last row is this branch's build on each kernel, back to back, 60 s runs.
Main's 2.70 W was another session; on the same build the two kernels are
within run-to-run noise (~0.2 W). At brightness 5 stock drives the backlight
at 22/255 and mainline at 5/255; at 22/255 mainline read 2.99–3.04 W.

Where the 0.6 W went, in game, 45 s points:

- **WiFi, ~350–450 mW.** The powered chip cost 1030 mW (cut: 2340 mW), and
  `wlan0` down saved nothing. zlyme's options turned station power save off,
  after a hotspot problem its own log puts down to distance. Stock runs
  `LPS mode: MAX` at level 0 ([power](power.md)), now set here:
  `rtw_power_mgnt=2` gave 3013 and 3017 mW, `=1` 3003, 2918 and 2909, off
  3357, with no ping loss in any. The deeper `rtw_lps_level`s are not
  built into this driver. Bluetooth audio still works with it, with the
  occasional dropout stock has too.
- **DDR, ~100 mW.** With no DMC driver it stayed at 1056 MHz; main's
  load-based rate sits at 324 MHz in this game, measured there at 153 mW.
  zlyme's DMC driver is now built in (`drivers/hardware/rk3568-dmc.c`, stock's
  40/20 thresholds), with its DFI suspend patch (`0035`): 324 MHz throughout
  the game, 2924 mW against ~3015. It returns to 1056 MHz before suspend; after
  a lid sleep it was back at 324 and still rose under load. Unlike stock, it
  does not tell BL31 about the VOP, so the switch is not timed to the
  panel's blanking; no glitch was seen.

Still to do:

- optional: Bluetooth audio dropouts, as on stock
- optional: per-chip voltages. Stock picks its OPP voltages by the chip's
  leakage bin, and mainline has no bin selection, so this unit runs the
  common table:
  - CPU: this unit is bin L3, where stock is lower from 1104 MHz up (1416 MHz:
    925 against 1025 mV). Both use 850 mV up to 816 MHz, where a Game Boy
    game spends ~97% of its time, so it matters for heavier cores.
  - `vdd_logic`: stock's DMC runs it at 875 mV, mainline at 900 mV, worth
    ~10–20 mW.

  Hardcoding either is unsafe on other units: it needs stock's bin read from
  the OTP, as the BSP's `rockchip_opp_select` does.
