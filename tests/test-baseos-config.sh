#!/bin/sh
# Offline tests for baseos-config: defaults, parsing, hostname validation and the
# root password, under BusyBox ash with its real mkpasswd. Adapted from upstream
# BaseOS's tests/test-baseos-config.sh. Runs in a container; no device.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/common.sh
. "$HERE/tools/common.sh"

echo "== baseos-config =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/overlay":/overlay:ro -v "$HERE/assets":/assets:ro alpine:3.20 sh -euc '
  SCRIPT=/overlay/usr/sbin/baseos-config
  TMP=/tmp/t; mkdir -p "$TMP/run" "$TMP/bin"
  export BASEOS_SHADOW_DEFAULT=/overlay/etc/shadow
  export BASEOS_RUN_ROOT="$TMP/run"
  export BASEOS_HOSTNAME_BIN="$TMP/bin/hostname"
  export BASEOS_TEST_LOG="$TMP/events"

  fail() { echo "FAIL: $*" >&2; exit 1; }
  printf "#!/bin/sh\n[ \$# -eq 1 ] || exit 1\necho \"hostname \$1\" >> \"\$BASEOS_TEST_LOG\"\n" \
    > "$TMP/bin/hostname"
  chmod 755 "$TMP/bin/hostname"

  apply() { rm -f "$TMP/run"/*; : > "$TMP/events"; sh "$SCRIPT" "$@"; }
  check() {
    [ "$(cat "$TMP/run/hostname")" = "$1" ] || fail "hostname file: $1"
    printf "127.0.0.1 localhost %s\n::1 localhost\n" "$1" > "$TMP/want"
    cmp -s "$TMP/want" "$TMP/run/hosts" || fail "hosts: $1"
    [ "$(cat "$TMP/events")" = "hostname $1" ] || fail "hostname must be set exactly once: $1"
  }
  default_shadow() { cmp -s "$BASEOS_SHADOW_DEFAULT" "$TMP/run/shadow" || fail "shadow not default"; }
  # The root hash must be what mkpasswd gives for $1 with the same salt.
  check_password() {
    h=$(sed -n "s/^root:\([^:]*\):.*/\1/p" "$TMP/run/shadow")
    salt=$(echo "$h" | cut -d\$ -f3)
    [ "$(printf "%s\n" "$1" | mkpasswd -m sha512 -S "$salt" -P 0)" = "$h" ] || fail "password: $1"
    grep -v "^root:" "$BASEOS_SHADOW_DEFAULT" > "$TMP/others-want"
    grep -v "^root:" "$TMP/run/shadow" > "$TMP/others-got"
    cmp -s "$TMP/others-want" "$TMP/others-got" || fail "other accounts changed"
    [ "$(stat -c %a "$TMP/run/shadow")" = 600 ] || fail "shadow mode"
  }

  # Defaults for no file, a missing file and the shipped template.
  apply; check miyoo-flip; default_shadow
  apply "$TMP/missing"; check miyoo-flip; default_shadow
  apply /assets/baseos.conf; check miyoo-flip; default_shadow
  # The baked password is root, as the docs say.
  install -m 600 "$BASEOS_SHADOW_DEFAULT" "$TMP/run/shadow"; check_password root

  # Whitespace, comments and CRLF, without accepting internal whitespace.
  printf " # comment\r\n\thostname \t= My-Flip \t# name\r\nunknown=ignored\r\n" > "$TMP/config"
  cp "$TMP/config" "$TMP/original"
  apply "$TMP/config"; check My-Flip
  cmp -s "$TMP/config" "$TMP/original" || fail "card file modified"
  printf "hostname=LastLine" > "$TMP/config"
  apply "$TMP/config"; check LastLine

  name63=$(printf "%063d" 0 | tr 0 a)
  printf "hostname=%s\n" "$name63" > "$TMP/config"
  apply "$TMP/config"; check "$name63"
  for bad in "" -bad bad- --help "two words" "two	tabs" bad.name bad_name bad/name \
      bad=name "é" "${name63}a" "\$(touch executed)"; do
    printf "hostname=%s\n" "$bad" > "$TMP/config"
    (cd "$TMP"; apply "$TMP/config"); check miyoo-flip
  done
  # A later invalid duplicate resets to the default.
  printf "hostname=first\nhostname=-bad\n" > "$TMP/config"
  apply "$TMP/config"; check miyoo-flip
  [ ! -e "$TMP/executed" ] || fail "hostname executed shell code"

  # Passwords are literal: #, = and shell syntax kept, surrounding blanks trimmed.
  printf "%s\r\n" "ssh_password=  secret#=\$(touch nope) x  " > "$TMP/config"
  (cd "$TMP"; apply "$TMP/config"); check miyoo-flip
  check_password "secret#=\$(touch nope) x"
  [ ! -e "$TMP/nope" ] || fail "password executed shell code"
  # An empty later value restores the default.
  printf "ssh_password=first\nssh_password=\n" > "$TMP/config"
  apply "$TMP/config"; default_shadow

  # No stray temporary file, and too many arguments are refused.
  [ ! -e "$TMP/run/shadow.tmp" ] || fail "shadow.tmp left behind"
  sh "$SCRIPT" a b 2>/dev/null && fail "two arguments accepted" || :
  echo "  ok"
'
