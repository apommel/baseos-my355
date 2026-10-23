#!/bin/sh
# Offline tests for wifibt-power: when the WiFi/BT chip is cut and restored,
# against a fake sysfs whose chip appears once wifi_power is 1, and stub
# insmod/rmmod editing a fake module list. Runs in a container; no device.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/common.sh
. "$HERE/tools/common.sh"

echo "== wifibt-power =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/overlay":/overlay:ro alpine:3.20 sh -euc '
  mkdir -p /usr/share/baseos /data /stub
  cp /overlay/usr/share/baseos/log.sh /usr/share/baseos/
  export WIFIBT_SYS=/t/sys WIFIBT_RUN=/t/run WIFIBT_MODULES=/t/modules
  CHIP=/t/sys/bus/usb/devices/2-1 RK=/t/sys/class/rkwifi

  # The chip enumerates on the first poll after power returns.
  cat > /stub/usleep <<"EOF"
#!/bin/sh
[ "$(cat /t/sys/class/rkwifi/wifi_power)" = 1 ] && mkdir -p /t/sys/bus/usb/devices/2-1
exit 0
EOF
  cat > /stub/insmod <<"EOF"
#!/bin/sh
echo insmod >> /t/calls; echo "rtk_btusb 1 0 - Live" >> /t/modules
EOF
  cat > /stub/rmmod <<"EOF"
#!/bin/sh
echo rmmod >> /t/calls
[ -e /t/busy ] && exit 1
sed -i "/^rtk_btusb /d" /t/modules
EOF
  chmod +x /stub/*
  export PATH=/stub:$PATH
  P=/overlay/usr/sbin/wifibt-power

  # $1 chip present|absent, $2 module loaded|unloaded; intents start at the defaults.
  setup() {
    rm -rf /t; mkdir -p $RK /t/run; : > /t/calls; : > /t/modules
    echo untouched > $RK/wifi_power
    [ "$1" = present ] && mkdir -p $CHIP
    [ "$2" = loaded ] && echo "rtk_btusb 1 0 - Live" > /t/modules
    return 0
  }
  state() {
    m=no; grep -q "^rtk_btusb " /t/modules && m=yes
    c=absent; [ -e $CHIP ] && c=present
    echo "power=$(cat $RK/wifi_power) chip=$c module=$m calls=$(tr "\n" , < /t/calls)"
  }
  n=0
  check() {
    n=$((n + 1)); got=$(state)
    [ "$got" = "$2" ] || { echo "FAIL $n $1"; echo "  got:  $got"; echo "  want: $2"; exit 1; }
    echo "ok $n $1"
  }

  setup present unloaded; sh $P want wifi
  check "default, WiFi on: nothing touched" \
    "power=untouched chip=present module=no calls="

  setup present unloaded; sh $P release wifi
  check "WiFi off, BT never started: cut" \
    "power=0 chip=present module=no calls="

  setup present loaded; sh $P release wifi
  check "WiFi off, rtk_btusb loaded but BT off: unloaded, then cut" \
    "power=0 chip=present module=no calls=rmmod,"

  setup present loaded; touch /t/busy; sh $P release wifi
  check "rtk_btusb will not unload: kept on" \
    "power=untouched chip=present module=yes calls=$(printf "rmmod,%.0s" $(seq 20))"

  setup present loaded; sh $P want bt; sh $P release wifi
  check "WiFi off while BT on: kept on" \
    "power=untouched chip=present module=yes calls="

  setup present loaded; sh $P want bt; sh $P release wifi; sh $P release bt
  check "then BT off too: unloaded, then cut" \
    "power=0 chip=present module=no calls=rmmod,"

  setup present loaded; sh $P want bt; sh $P release bt
  check "BT off while WiFi on: kept on, module left alone" \
    "power=untouched chip=present module=yes calls="

  setup absent unloaded; sh $P release wifi; sh $P want wifi
  check "chip cut, WiFi on: restored, no BT module" \
    "power=1 chip=present module=no calls="

  setup absent loaded; sh $P release wifi; sh $P want bt
  check "chip cut, BT on (bt_init.sh loaded rtk_btusb): restored" \
    "power=1 chip=present module=yes calls="

  setup absent unloaded; sh $P release wifi; sh $P want bt
  check "chip cut, BT on after a cut unloaded its module: restored and reloaded" \
    "power=1 chip=present module=yes calls=insmod,"

  setup absent unloaded; sh $P release bt
  check "BT off with the chip cut by another rail owner: left cut" \
    "power=untouched chip=absent module=no calls="

  setup present unloaded; sh $P bogus wifi && exit 1 || true
  check "unknown command: nothing touched" \
    "power=untouched chip=present module=no calls="

  echo "all $n passed"
'
