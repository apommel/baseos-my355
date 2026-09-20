#!/bin/sh
# Offline tests for the fuel gauge decision in `my355 fg` (patch 0001): when a
# boot keeps the SOC the kernel last saved, and when the coulomb counter is
# allowed to move it. Runs in a container; no device needed.
#
# The decision lives inside do_my355_fg wrapped around its I2C, so the harness
# restates it; only the constants come from the patch, which at least catches a
# changed threshold. Each case below is a boot this unit actually did, with the
# numbers its `my355 fg:` line reported — this is the regression suite for a
# rule that has been got wrong twice.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/common.sh
. "$HERE/tools/common.sh"

PATCH="$HERE/tools/uboot/patches/0001-cmd-add-my355-boot-helpers.patch"
[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed -n '/^+++ b\/cmd\/my355\.c$/,$p' "$PATCH" | sed '1,2d' | sed 's/^+//' \
	> "$WORK/my355.c"
sed -n '/^#define RK817_FULL/p;/^#define RK817_CHRG_MIN/p' "$WORK/my355.c" \
	> "$WORK/defines.h"
[ "$(grep -c . "$WORK/defines.h")" = 2 ] ||
	{ echo "could not extract the constants from $PATCH" >&2; exit 1; }

cat > "$WORK/harness.c" <<'EOF'
#include <stdio.h>

#define clamp(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))
#define min(a, b) ((a) < (b) ? (a) : (b))
#include "defines.h"

/* do_my355_fg()'s decision, from `now_cap >` to the clamps. An invalid
 * (negative) counter reaches it as now_cap = 0. */
static int decide(int pre_soc, int pre_cap, int now_cap, int fcc,
		  int *charged, int *out_cap)
{
	int soc, cap;

	*charged = 0;
	if (now_cap > pre_cap + RK817_CHRG_MIN) {
		cap = min(now_cap, fcc);
		soc = pre_soc + (cap - pre_cap) * RK817_FULL / fcc;
		if (cap == fcc)
			soc = RK817_FULL;
		*charged = 1;
	} else {
		soc = pre_soc;
		cap = pre_cap;
	}
	*out_cap = clamp(cap, 0, fcc);
	return clamp(soc, 0, RK817_FULL);
}

static int fails;

static void check(const char *name, int got, int want)
{
	if (got != want)
		fails++;
	printf("  %-46s %-8d %s\n", name, got, got == want ? "ok" : "FAIL");
}

/* pre_soc, pre_cap, now_cap, fcc, want_soc, want_charged, what happened */
static const struct {
	int pre_soc, pre_cap, now_cap, fcc, soc, charged;
	const char *name;
} boots[] = {
	{ 100000, 3000,  330, 3000, 100000, 0, "9.4 h off, full: counter fell to 330 mAh" },
	{ 100000, 3000, 2888, 3000, 100000, 0, "4h20m off, full: counter fell to 2888" },
	{ 100000, 3000, 2998, 3000, 100000, 0, "warm reboot: counter barely moved" },
	{  74999, 2346, 2062, 3000,  74999, 0, "70 min off at 75%: counter fell to 2062" },
	{  84000, 2505,    0, 3000,  84000, 0, "~11 h off at 84%: counter went negative (read as 0)" },
	{  11993,    0, 2000, 3000,  78659, 1, "charged while off, from a corrupted 12%" },
	{  90000, 2700, 3000, 3000, 100000, 1, "charged to full while off" },
};

int main(void)
{
	int i, charged, cap, soc;

	printf("boots this unit did\n");
	for (i = 0; i < (int)(sizeof(boots) / sizeof(boots[0])); i++) {
		soc = decide(boots[i].pre_soc, boots[i].pre_cap, boots[i].now_cap,
			     boots[i].fcc, &charged, &cap);
		printf("  %s\n", boots[i].name);
		check("    soc", soc, boots[i].soc);
		check("    counter believed", charged, boots[i].charged);
	}

	printf("edges\n");
	soc = decide(50000, 1500, 1510, 3000, &charged, &cap);
	check("a 10 mAh rise is drift, not charge", charged, 0);
	soc = decide(50000, 1500, 1511, 3000, &charged, &cap);
	check("11 mAh is charge", charged, 1);
	soc = decide(100000, 3000, 3500, 3000, &charged, &cap);
	check("a counter past fcc cannot exceed 100%", soc, 100000);
	check("nor can the capacity exceed fcc", cap, 3000);

	printf("\n%s\n", fails ? "FAILURES" : "all checks passed");
	return fails ? 1 : 0;
}
EOF

echo "== my355 fg =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
	-v "$WORK":/work:ro alpine:3.20 sh -euc '
	apk add -q build-base
	cc -O2 -Wall -I/work -o /tmp/t /work/harness.c
	/tmp/t
'
