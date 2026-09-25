#!/bin/sh
# Exercise the real DHCP hook and baseos-mdns with stub network and Avahi
# commands. From upstream BaseOS's tests/test-baseos-mdns.sh. Runs under
# BusyBox in a container, for its flock and the shell the image uses.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${BASEOS_IN_TEST_CONTAINER:-}" ]; then
	echo "== baseos-mdns =="
	# shellcheck source=../tools/common.sh
	. "$HERE/tools/common.sh"
	exec docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" -e BASEOS_IN_TEST_CONTAINER=1 \
		-v "$HERE:/src:ro" alpine:3.20 sh /src/tests/test-baseos-mdns.sh
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
HELPER="$HERE/overlay/usr/sbin/baseos-mdns"
DHCP="$TMP/default.script"
export MDNS_TEST_DIR="$TMP"
export BASEOS_MDNS_CONFIG="$TMP/baseos.conf"
export BASEOS_MDNS_LOCK_FILE="$TMP/mdns.lock"
export BASEOS_MDNS_DAEMON="$TMP/avahi-daemon"
export BASEOS_MDNS_HELPER="$TMP/mdns-hook"
export MDNS_TEST_HELPER="$HELPER"
export BASEOS_DHCP_RESOLV_CONF="$TMP/resolv.conf"
mkdir "$TMP/bin"
sed -e 's|^RESOLV=.*|RESOLV="$BASEOS_DHCP_RESOLV_CONF"|' \
	-e 's|^MDNS=.*|MDNS="$BASEOS_MDNS_HELPER"|' \
	"$HERE/overlay/usr/share/udhcpc/default.script" > "$DHCP"
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $1" >&2; exit 1; }
wait_for() {
	n=0
	until "$@"; do
		n=$((n + 1))
		[ "$n" -lt 100 ] || fail "timed out: $*"
		sleep 0.02
	done
}
starts() { grep -c '^start$' "$TMP/daemon.log" || true; }
stops() { grep -c '^stop$' "$TMP/daemon.log" || true; }
refresh() { sh "$HELPER" refresh "${1:-wlan0}"; }
expected_hooks=0
hooks_done() { [ "$(wc -l < "$TMP/hooks-done")" -eq "$expected_hooks" ]; }
settle_dhcp() { wait_for hooks_done; }
lease() {
	interface="${2:-wlan0}" ip=192.0.2.2 mask=24 router=192.0.2.1 \
		domain=example.test dns='192.0.2.53 192.0.2.54' \
		timeout 2 sh "$DHCP" "$1"
	case "$1:${2:-wlan0}" in
		deconfig:wlan0|bound:wlan0|renew:wlan0) expected_hooks=$((expected_hooks + 1)) ;;
	esac
}

cat > "$TMP/mdns-hook" <<'STUB'
#!/bin/sh
sh "$MDNS_TEST_HELPER" "$@"
status="$?"
printf 'done\n' >> "$MDNS_TEST_DIR/hooks-done"
exit "$status"
STUB

cat > "$TMP/bin/ip" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$MDNS_TEST_DIR/ip.log"
case "$*" in
	'-4 addr show dev wlan0 up')
		if [ -e "$MDNS_TEST_DIR/address" ] && [ ! -e "$MDNS_TEST_DIR/down" ]; then
			printf '    inet 192.0.2.2/24 scope global wlan0\n'
		fi
		;;
	'addr flush dev wlan0') rm -f "$MDNS_TEST_DIR/address" ;;
	'addr add '*'/24 dev wlan0') touch "$MDNS_TEST_DIR/address" ;;
	'link set wlan0 up') rm -f "$MDNS_TEST_DIR/down" ;;
esac
STUB

cat > "$TMP/avahi-daemon" <<'STUB'
#!/bin/sh
set -eu
# A forked daemon inheriting this descriptor would hold the flock forever.
if ( : >&9 ) 2>/dev/null; then
	touch "$MDNS_TEST_DIR/inherited-lock"
fi
case "$1" in
	--check) test -e "$MDNS_TEST_DIR/running" ;;
	--daemonize)
		[ "$*" = '--daemonize --no-drop-root --no-proc-title' ] || exit 1
		printf 'start\n' >> "$MDNS_TEST_DIR/daemon.log"
		# Model Avahi's parent/child startup handshake, making the race visible.
		while [ -e "$MDNS_TEST_DIR/start-gate" ]; do sleep 0.02; done
		sleep 0.05
		touch "$MDNS_TEST_DIR/running"
		;;
	--kill)
		printf 'stop\n' >> "$MDNS_TEST_DIR/daemon.log"
		rm -f "$MDNS_TEST_DIR/running"
		;;
	*) exit 2 ;;
esac
STUB
chmod 755 "$TMP/bin/ip" "$TMP/avahi-daemon" "$TMP/mdns-hook"
: > "$TMP/daemon.log"
: > "$TMP/hooks-done"

# No address means no process, even with mDNS enabled by default.
refresh
[ "$(starts)" -eq 0 ] || fail 'started before a lease'

# Missing configuration defaults to enabled. DHCP must return while Avahi is
# still starting, and must preserve its normal address/route/DNS work.
touch "$TMP/start-gate"
lease bound
wait_for test -s "$TMP/daemon.log"
[ ! -e "$TMP/running" ] || fail 'startup gate was not exercised'
grep -qx 'addr add 192.0.2.2/24 dev wlan0' "$TMP/ip.log" || fail 'DHCP address lost'
grep -qx 'route add default via 192.0.2.1 dev wlan0' "$TMP/ip.log" || fail 'DHCP route lost'
printf 'search example.test\nnameserver 192.0.2.53\nnameserver 192.0.2.54\n' > "$TMP/expected-resolv"
cmp "$TMP/expected-resolv" "$TMP/resolv.conf" || fail 'DHCP DNS changed'

# Several queued starts while the daemon is handshaking must not duplicate it.
jobs=""
for n in 1 2 3 4 5 6; do
	refresh &
	jobs="$jobs $!"
done
rm "$TMP/start-gate"
for job in $jobs; do wait "$job"; done
wait_for test -e "$TMP/running"
settle_dhcp
[ "$(starts)" -eq 1 ] || fail 'concurrent requests duplicated the daemon'
lease renew
settle_dhcp
[ "$(starts)" -eq 1 ] || fail 'renew restarted the daemon'

# Other interfaces and unrelated DHCP events must not touch the responder.
printf 'mdns=false\n' > "$TMP/baseos.conf"
refresh eth0
lease deconfig eth0
lease leasefail
settle_dhcp
[ -e "$TMP/running" ] || fail 'unrelated interface/event stopped mDNS'

# An explicit false stops an existing process and prevents later starts.
refresh
[ ! -e "$TMP/running" ] || fail 'disabled config did not stop mDNS'
lease bound
settle_dhcp
[ "$(starts)" -eq 1 ] || fail 'disabled config started mDNS'

# A missing key, or unrecognized values, retains the enabled default. The
# helper parses a key/value file rather than evaluating its contents as shell.
printf 'hostname=fixture-device\n' > "$TMP/baseos.conf"
refresh
[ "$(starts)" -eq 2 ] || fail 'missing mdns key did not default to enabled'
sh "$HELPER" stop
printf 'mdns=$(touch %s)\n' "$TMP/injected" > "$TMP/baseos.conf"
refresh
[ -e "$TMP/running" ] || fail 'invalid value did not retain default'
[ ! -e "$TMP/injected" ] || fail 'configuration was evaluated as shell'

# Deconfig flushes the address, then asynchronously stops the daemon.
lease deconfig
settle_dhcp
wait_for test ! -e "$TMP/running"
before="$(starts)"
lease bound
settle_dhcp
wait_for test -e "$TMP/running"
[ "$(starts)" -eq "$((before + 1))" ] || fail 'reconnect did not restart mDNS'

# Queued refreshes must observe the latest interface/config state under the
# lock, not the older DHCP event that queued them.
exec 8>"$TMP/mdns.lock"
flock -x 8
rm "$TMP/address"
refresh &
queued="$!"
touch "$TMP/address"
flock -u 8
wait "$queued"
[ -e "$TMP/running" ] || fail 'stale deconfig stopped a newer connection'

flock -x 8
refresh &
queued="$!"
printf 'mdns=false\n' > "$TMP/baseos.conf"
flock -u 8
wait "$queued"
[ ! -e "$TMP/running" ] || fail 'queued start ignored latest disabled config'
exec 8>&-

# An interface administratively down cannot start a responder on a stale IP.
printf 'mdns=true\n' > "$TMP/baseos.conf"
touch "$TMP/down"
before="$(starts)"
refresh
[ "$(starts)" -eq "$before" ] || fail 'started on a down interface'
[ "$(stops)" -ge 4 ] || fail 'stop paths were not exercised'
[ ! -e "$TMP/inherited-lock" ] || fail 'Avahi inherited the lifecycle lock'
[ -e "$TMP/mdns.lock" ] || fail 'helper unlinked its lock file'

echo '  ok'
