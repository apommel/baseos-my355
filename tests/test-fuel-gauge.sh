#!/bin/sh
# Offline tests for the fuel gauge decision in `my355 fg` (patch 0001): when a
# boot keeps the SOC the kernel last saved, and when the coulomb counter is
# allowed to move it. Runs in a container; no device needed.
#
# rk817_fg_decide() is compiled as it stands in the patch, with the constants
# and enum it uses. Each boot case below is one this unit actually did, with
# the numbers its `my355 fg:` line reported — this is the regression suite for
# a rule that has been got wrong twice.
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
{
	sed -n '/^#define RK817_FULL/p;/^#define RK817_CHRG_MIN/p' "$WORK/my355.c"
	sed -n '/^enum rk817_fg_basis {$/,/^};$/p' "$WORK/my355.c"
	sed -n '/^static bool rk817_fg_decide(/,/^}$/p' "$WORK/my355.c"
} > "$WORK/decide.h"
grep -q '^static bool rk817_fg_decide' "$WORK/decide.h" &&
	grep -q '^enum rk817_fg_basis' "$WORK/decide.h" &&
	[ "$(grep -c '^#define' "$WORK/decide.h")" = 2 ] ||
	{ echo "could not extract rk817_fg_decide() from $PATCH" >&2; exit 1; }

cat > "$WORK/harness.c" <<'EOF'
#include <stdbool.h>
#include <stdio.h>

#define clamp(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))
#define min(a, b) ((a) < (b) ? (a) : (b))
#include "decide.h"

static int fails;

static void check(const char *name, int got, int want)
{
	if (got != want)
		fails++;
	printf("  %-46s %-8d %s\n", name, got, got == want ? "ok" : "FAIL");
}

/* An invalid (negative) counter reaches the decision as now_cap = 0 */
static const struct {
	int pre_soc, pre_cap, now_cap, fcc, soc, moved;
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
	int i, soc, cap;
	bool moved;

	printf("boots this unit did\n");
	for (i = 0; i < (int)(sizeof(boots) / sizeof(boots[0])); i++) {
		moved = rk817_fg_decide(RK817_FG_BOOT, boots[i].pre_soc,
					boots[i].pre_cap, boots[i].now_cap,
					boots[i].fcc, &soc, &cap);
		printf("  %s\n", boots[i].name);
		check("    soc", soc, boots[i].soc);
		check("    counter believed", moved, boots[i].moved);
	}

	printf("edges, after a power-off\n");
	moved = rk817_fg_decide(RK817_FG_BOOT, 50000, 1500, 1510, 3000, &soc, &cap);
	check("a 10 mAh rise is drift, not charge", moved, 0);
	moved = rk817_fg_decide(RK817_FG_BOOT, 50000, 1500, 1511, 3000, &soc, &cap);
	check("11 mAh is charge", moved, 1);
	rk817_fg_decide(RK817_FG_BOOT, 100000, 3000, 3500, 3000, &soc, &cap);
	check("a counter past fcc cannot exceed 100%", soc, 100000);
	check("nor can the capacity exceed fcc", cap, 3000);

	printf("counted while U-Boot ran (leaving charge mode)\n");
	rk817_fg_decide(RK817_FG_AWAKE, 50000, 1500, 1505, 3000, &soc, &cap);
	check("a 5 mAh rise is taken", soc, 50166);
	rk817_fg_decide(RK817_FG_AWAKE, 50000, 1500, 1470, 3000, &soc, &cap);
	check("so is a 30 mAh fall", soc, 49000);
	moved = rk817_fg_decide(RK817_FG_AWAKE, 50000, 1500, 0, 3000, &soc, &cap);
	check("an invalid counter moves nothing", moved, 0);
	check("    soc kept", soc, 50000);

	printf("charge terminated\n");
	rk817_fg_decide(RK817_FG_FULL, 80000, 2400, 2500, 3000, &soc, &cap);
	check("100% whatever the counter", soc, 100000);
	check("and the full capacity", cap, 3000);

	printf("\n%s\n", fails ? "FAILURES" : "all checks passed");
	return fails ? 1 : 0;
}
EOF

echo "== my355 fg =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
	-v "$WORK":/work:ro alpine:3.20 sh -euc '
	apk add -q build-base
	cc -O2 -Wall -Werror -I/work -o /tmp/t /work/harness.c
	/tmp/t
'
