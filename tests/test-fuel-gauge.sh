#!/bin/sh
# Offline tests for the fuel gauge arithmetic in `my355 fg` (patch 0001): the
# factory voltage calibration, the OCV table lookup, and the choice between the
# voltage and the coulomb counter. Runs in a container; no device needed.
#
# The code under test is extracted from the patch, not copied, so an edit to
# cmd/my355.c is what runs here. Only the choice itself is restated in the
# harness, because it lives inside do_my355_fg wrapped around the I2C.
#
# The register values and the boots they came from are real, measured on the
# unit on 2026-09-20 (docs/uboot.md, *What the kernel relied on the vendor
# U-Boot for*).
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/common.sh
. "$HERE/tools/common.sh"

PATCH="$HERE/tools/uboot/patches/0001-cmd-add-my355-boot-helpers.patch"
[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# cmd/my355.c as the patch creates it
sed -n '/^+++ b\/cmd\/my355\.c$/,$p' "$PATCH" | sed '1,2d' | sed 's/^+//' \
	> "$WORK/my355.c"

# The pieces under test, verbatim. Each must come out non-empty or the patch
# has been restructured and this test is no longer looking at the real thing.
extract() {
	sed -n "$1" "$WORK/my355.c" > "$WORK/$2"
	[ -s "$WORK/$2" ] || { echo "extract failed: $2 ($1)" >&2; exit 1; }
}
extract '/^#define RK817_FULL/p;/^#define RK817_MAX_DRIFT/p;/^#define RK817_VOL_MIN/p;/^#define RK817_VOL_MAX/p' defines.h
extract '/^static const u16 rk817_ocv_mv\[\]/,/^};/p' table.h
extract '/^static int rk817_read_be16/,/^}/p' read_be16.h
extract '/^static int rk817_ocv_soc/,/^}/p' ocv_soc.h
# The register names the extracted code reads
extract '/^#define RK817_PWRON_VOL_H/p;/^#define RK817_VCALIB0_H/p;/^#define RK817_VCALIB1_H/p' regs.h

cat > "$WORK/harness.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef uint16_t u16;
typedef unsigned int uint;
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define clamp(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))

/* The PMIC, as a register file: only the ones the extracted code reads. */
struct udevice { unsigned char reg[256]; };

static int dm_i2c_reg_read(struct udevice *dev, unsigned int reg)
{
	return reg < 256 ? dev->reg[reg] : -1;
}

#include "regs.h"
#include "defines.h"
#include "table.h"
#include "read_be16.h"
#include "ocv_soc.h"

/* The unit's factory calibration, registers 0x93-0x96 */
#define CAL0 0x8019
#define CAL1 0xdfd2

static struct udevice *pmic(int cal0, int cal1, int pwron)
{
	static struct udevice d;

	d.reg[RK817_VCALIB0_H] = cal0 >> 8;
	d.reg[RK817_VCALIB0_H + 1] = cal0 & 0xff;
	d.reg[RK817_VCALIB1_H] = cal1 >> 8;
	d.reg[RK817_VCALIB1_H + 1] = cal1 & 0xff;
	d.reg[RK817_PWRON_VOL_H] = pwron >> 8;
	d.reg[RK817_PWRON_VOL_H + 1] = pwron & 0xff;
	return &d;
}

/* The decode, to turn a target millivolt back into a raw ADC value. The
 * decode truncates, so inverting it arithmetically lands a millivolt short. */
static int mv_of(int raw)
{
	int k = (4025 - 2300) * 1000 / (CAL1 - CAL0);
	int b = 4025 - k * CAL1 / 1000;

	return k * raw / 1000 + b;
}

static int raw_for(int mv)
{
	int raw;

	for (raw = 0; raw < 0x10000; raw++)
		if (mv_of(raw) == mv)
			return raw;
	fprintf(stderr, "no raw value decodes to %d mV\n", mv);
	exit(1);
}

/*
 * do_my355_fg()'s reconciliation, from `ocv_soc =` to the `cap == fcc` clamp.
 * Restated because the original is wrapped around its I2C; `off` is OFF_CNT,
 * the flag that picks the branch.
 */
static int reconcile(int pre_soc, int pre_cap, int now_cap, int fcc, int off,
		     struct udevice *dev, int *by_ocv, int *out_cap)
{
	int ocv_soc = rk817_ocv_soc(dev);
	int soc, cnt_soc, cap;

	*by_ocv = 0;
	if (off && ocv_soc >= 0) {
		soc = ocv_soc;
		now_cap = ocv_soc * fcc / RK817_FULL;
		*by_ocv = 1;
	} else {
		soc = pre_soc + (now_cap - pre_cap) * RK817_FULL / fcc;
		cnt_soc = now_cap * RK817_FULL / fcc;
		if (abs(soc - cnt_soc) > RK817_MAX_DRIFT)
			soc = cnt_soc;
	}
	soc = clamp(soc, 0, RK817_FULL);
	cap = clamp(now_cap, 0, fcc);
	if (cap == fcc)
		soc = RK817_FULL;
	*out_cap = cap;
	return soc;
}

static int fails;

static void check(const char *name, int got, int want)
{
	int ok = got == want;

	if (!ok)
		fails++;
	printf("  %-48s %-9d %s\n", name, got, ok ? "ok" : "FAIL");
}

static int soc_at(int mv) { return rk817_ocv_soc(pmic(CAL0, CAL1, raw_for(mv))); }

int main(void)
{
	int by_ocv, cap, soc;

	printf("voltage decode (VCALIB0=0x%04x VCALIB1=0x%04x)\n", CAL0, CAL1);
	/* BAT_VOL read 0xe763 while sysfs reported voltage_now=4161000 */
	check("BAT_VOL 0xe763 -> mV (sysfs said 4161)", mv_of(0xe763), 4161);
	/* PWRON_VOL, latched at the 2026-09-20 power-on */
	check("PWRON_VOL 0xe9be -> mV", mv_of(0xe9be), 4203);

	printf("ocv table\n");
	check("3378 mV -> 0% (table bottom)", soc_at(3378), 0);
	check("3722 mV -> 55% (table entry 11)", soc_at(3722), 55000);
	check("3699 mV -> 52.5% (interpolated)", soc_at(3699), 52500);
	check("4150 mV -> 100% (table top)", soc_at(4150), 100000);
	check("4203 mV -> 100% (above the top)", soc_at(4203), 100000);
	check("2000 mV -> rejected, not a battery", soc_at(2000), -1);
	check("4600 mV -> rejected, not a battery", soc_at(4600), -1);

	/* The next four are boots this unit actually did; the rest are made up. */
	printf("cold boot after ~9.4 h off: counter at 330 mAh, cell full\n");
	soc = reconcile(100000, 3000, 330, 3000, 255,
			pmic(CAL0, CAL1, 0xe9be), &by_ocv, &cap);
	check("soc (the old code handed on 11000)", soc, 100000);
	check("taken from the voltage", by_ocv, 1);
	check("capacity rewritten to match", cap, 3000);

	printf("cold boot after 4 h off: counter at 2888 mAh, cell full\n");
	soc = reconcile(100000, 3000, 2888, 3000, 26,
			pmic(CAL0, CAL1, 0xe6df), &by_ocv, &cap);
	check("soc (the old code handed on 96267)", soc, 100000);
	check("taken from the voltage", by_ocv, 1);

	printf("warm reboot: the counter is the good one\n");
	soc = reconcile(100000, 3000, 2998, 3000, 0,
			pmic(CAL0, CAL1, 0xe6df), &by_ocv, &cap);
	check("soc (the unit logged 99.934%)", soc, 99934);
	check("not taken from the voltage", by_ocv, 0);

	printf("warm reboot, counter far from the saved soc\n");
	soc = reconcile(31569, 3000, 2997, 3000, 0,
			pmic(CAL0, CAL1, 0xe9be), &by_ocv, &cap);
	check("soc (the unit logged 99.900%)", soc, 99900);
	check("not taken from the voltage", by_ocv, 0);

	/* The regression this design must not introduce: on a warm reboot
	 * PWRON_VOL is whatever the last real power-on saw, which can be
	 * anything. Charged from 15% to 95%, then rebooted. */
	printf("warm reboot must ignore a stale PWRON_VOL\n");
	soc = reconcile(95000, 2850, 2850, 3000, 0,
			pmic(CAL0, CAL1, raw_for(3500)), &by_ocv, &cap);
	check("soc stays at the counter's 95%", soc, 95000);
	check("not taken from the voltage", by_ocv, 0);

	printf("cold boot on a genuinely flat battery\n");
	soc = reconcile(100000, 3000, 3000, 3000, 12,
			pmic(CAL0, CAL1, raw_for(3500)), &by_ocv, &cap);
	check("soc follows the voltage down", soc, 15000);
	check("taken from the voltage", by_ocv, 1);
	check("capacity rewritten to match", cap, 450);

	printf("cold boot with an unreadable voltage falls back to the counter\n");
	soc = reconcile(100000, 3000, 2888, 3000, 26,
			pmic(CAL0, CAL1, raw_for(2000)), &by_ocv, &cap);
	check("soc from the counter", soc, 96267);
	check("not taken from the voltage", by_ocv, 0);

	printf("\n%s\n", fails ? "FAILURES" : "all checks passed");
	return fails ? 1 : 0;
}
EOF

echo "== my355 fg =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
	-v "$WORK":/work:ro alpine:3.20 sh -euc '
	apk add -q build-base
	cc -O2 -Wall -Wno-sign-compare -I/work -o /tmp/t /work/harness.c
	/tmp/t
'
