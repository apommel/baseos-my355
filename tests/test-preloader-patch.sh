#!/bin/sh
# The two preloader patchers must agree: tools/mkpreloader.py on the host and
# tools/preloader-installer/patch-preloader.sh + fdtpatch.awk on the device, in
# BusyBox alone. A divergence would mean the card writes a preloader the host
# tool never validated, so this compares their output byte for byte against a
# synthetic image. No device and no vendor preloader needed.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

echo "== preloader patch =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/tools":/tools:ro -v "$HERE/tests":/tests:ro \
  alpine:3.20 sh -euc '
  apk add -q python3 xxd
  cd /tmp

  python3 /tests/make_preloader_fixture.py fixture.img
  python3 /tools/mkpreloader.py fixture.img py.img > py.log
  AWK_SCRIPT=/tools/preloader-installer/fdtpatch.awk \
    sh /tools/preloader-installer/patch-preloader.sh fixture.img sh.img > sh.log
  cmp py.img sh.img || { echo "the two patchers disagree" >&2; exit 1; }
  [ "$(wc -c < py.img)" -eq 2097152 ] || { echo "size changed" >&2; exit 1; }

  # Both refuse an image that already carries the properties, which is what
  # leaves an already-patched unit and GammaLoader alone.
  if python3 /tools/mkpreloader.py sh.img again.img > /dev/null 2>&1; then
    echo "mkpreloader.py patched an already-patched image" >&2; exit 1
  fi
  if AWK_SCRIPT=/tools/preloader-installer/fdtpatch.awk \
       sh /tools/preloader-installer/patch-preloader.sh sh.img again.img > /dev/null 2>&1; then
    echo "patch-preloader.sh patched an already-patched image" >&2; exit 1
  fi

  # And a payload corrupted inside the first IDB copy, before writing anything:
  # the stored SHA-256 is what says the image is intact.
  cp fixture.img bad.img
  printf "\\xde\\xad" | dd of=bad.img bs=1 seek=140000 conv=notrunc status=none
  if python3 /tools/mkpreloader.py bad.img nope.img > /dev/null 2>&1; then
    echo "mkpreloader.py accepted a corrupt image" >&2; exit 1
  fi
  if AWK_SCRIPT=/tools/preloader-installer/fdtpatch.awk \
       sh /tools/preloader-installer/patch-preloader.sh bad.img nope.img > /dev/null 2>&1; then
    echo "patch-preloader.sh accepted a corrupt image" >&2; exit 1
  fi

  echo "  PASS both patchers agree byte for byte, and fail closed"
'
