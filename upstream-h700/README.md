# What is BaseOS?

BaseOS is a minimal but feature-complete operating system for Anbernic RG XX handhelds.

If you're tired of slow boot times, high battery consumption, or less than ideal
support for hardware features on other custom firmwares, BaseOS is for you.

It is designed as a drop-in replacement for the stock OS. However, BaseOS does not have a user interface of its own. It will boot up as fast as possible, then hand off to your frontend of choice.

Currently, that frontend is [NextUI](https://nextui.loveretro.games), but more might be added.

[Install BaseOS](https://github.com/pvaibhav/BaseOS/wiki/BaseOS-Install-Guide)

## Boot duration

We have a hard ceiling of 3.0 sec boot time. On top of that is NextUI which takes another 4.5 sec for a total of around 7.5 sec startup time.

* **2.96 s BaseOS only** - power LED to frontend handoff.
* **7.14 s BaseOS + NextUI** - power LED to NextUI, ready-to-game on RG40XXV.

By comparison, stock Anbernic OS + NextUI takes 17.5 sec (manually measured with a stopwatch). Knulli takes 22 sec.

## What BaseOS provides

- The fastest possible boot time for Anbernic RG XX devices.
- Lowest possible resource and battery usage.
- Takes 5 sec to install.
- Full support for the handheld's display, sound, controls, networking, HDMI, LEDs,
  deep sleep and other features. No comporise on that front.
- First-boot expansion of the data partition to fill the SD card.
- Easy updates: copy one file onto the card and reboot. No reflashing, and
  your ROMs, saves and settings are untouched.
- SSH/SFTP over Wi-Fi and adb over USB active by default.
- USB storage mode (hold MENU when powering on).

## Installation

Follow **[installation guide](https://github.com/pvaibhav/BaseOS/wiki/BaseOS-Install-Guide)** for flashing, first boot, and NextUI setup on
one-card or two-card configurations.

## Supported devices

- Anbernic RG28XX
- Anbernic RG34XX
- Anbernic RG34XX SP
- Anbernic RG35XX Plus and RG35XX 2024
- Anbernic RG35XX H
- Anbernic RG35XX Pro
- Anbernic RG35XX SP
- Anbernic RG40XX H
- Anbernic RG40XX V
- Anbernic RG CubeXX
- Anbernic RG SP

Development setup, build instructions, testing, and technical documentation are in
**[CONTRIBUTING.md](CONTRIBUTING.md)**.

## USB access

For reliable adb, connect a data-capable USB-C cable before powering on. If it
is disconnected, restart with the cable connected.

For USB mass storage, press and hold the MENU key while plugging in the USB cable. If your computer provides power, your handheld will start in mass storage mode. If it doesn't start, press and hold power for 3-4 sec. Let go when it start, but *keep pressing the MENU button* till you finally see "USB MASS STORAGE" on the screen. Then you can let go.

NOTE: Eject the drive on the computer before restarting the handheld. Restart without
holding MENU to return to normal.

## How does it work?

BaseOS is derived from the stock Anbernic OS for H700-based handhelds. The 
kernel, drivers, DTB etc are untouched, giving you perfect hardware support.
However, it replaces the stock Ubuntu userland with a custom BusyBox based
rootfs. We retain all required features like WiFi, GLES, Bluetooth etc. but
cut down everything else running in the background or increasing the boot
duration. Some parts of the stock OS are simulated to make them faster
yet compatible.

The current version is generally based on the latest stock/stockmod OS release.
