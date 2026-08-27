// gptslot — A/B slot arithmetic for the BaseOS GPT.
//
//   gptslot /dev/mmcblk1 geometry       print eval-able SLOT_* variables
//   gptslot /dev/mmcblk1 flip NAME...   point those entries at their other half
//
// The card reserves twice the space `uboot`, `boot` and `rootfs` each need, and
// only ever makes one half a partition; the other is unallocated space reached
// by raw offset. Nothing in the boot chain references an address — the SPL finds
// `uboot` by name, U-Boot's boot_android finds `boot` by name, and
// root=/dev/mmcblk1p3 names an entry number — so moving an entry between its two
// halves is what selects the slot, and one GPT write commits all three.
//
// Geometry comes from the table alone: the regions tile forward from LBA 16384,
// each twice its entry's size, and `data` must start exactly where the last one
// ends. Any other layout is refused, so a card without the reserved halves fails
// closed instead of having one written over its data.
//
// Exit: 0 success, 2 usage, IO error or invalid layout.
#include <fcntl.h>
#include <stdio.h>

#include "gpt.h"

#define UBOOT_START 16384   // fixed by the SPL (docs/02-sd-boot.md)
#define NSLOTS 3

static const char *NAMES[NSLOTS] = {"uboot", "boot", "rootfs"};
static const char *UPPER[NSLOTS] = {"UBOOT", "BOOT", "ROOTFS"};

struct slot {
	int idx;            // entry index
	uint64_t sectors;   // sectors per half
	uint64_t active, inactive;
	char letter;        // 'A' or 'B'
};

static int fail(const char *msg) {
	fprintf(stderr, "gptslot: %s\n", msg);
	return 2;
}

static int derive(struct gpt *g, struct slot *s) {
	uint64_t base = UBOOT_START;
	for (int i = 0; i < NSLOTS; i++) {
		int idx = gpt_find(g, NAMES[i]);
		if (idx < 0) return -1;
		uint64_t start = gpt_rd64(gpt_entry(g, idx) + GPT_START);
		uint64_t end = gpt_rd64(gpt_entry(g, idx) + GPT_END);
		if (end <= start) return -1;
		uint64_t n = end - start + 1;
		if (start == base) s[i].letter = 'A';
		else if (start == base + n) s[i].letter = 'B';
		else return -1;
		s[i].idx = idx;
		s[i].sectors = n;
		s[i].active = start;
		s[i].inactive = (s[i].letter == 'A') ? base + n : base;
		base += 2 * n;
	}
	int data = gpt_find(g, "data");
	if (data < 0 || gpt_rd64(gpt_entry(g, data) + GPT_START) != base) return -1;
	return 0;
}

// Refresh both headers' CRCs and write them, backup first: if power is lost
// mid-commit the primary still describes the old halves, and every consumer
// here (SPL, U-Boot, the kernel) reads the primary.
static int commit(int fd, struct gpt *g) {
	uint32_t table_crc = gpt_crc32(g->table, g->table_bytes);
	uint64_t backup_lba = gpt_rd64(g->hdr + 32);

	uint8_t bak[SECTOR];
	if (pread(fd, bak, SECTOR, backup_lba * SECTOR) != SECTOR ||
	    memcmp(bak, "EFI PART", 8) != 0)
		return fail("no backup GPT header");
	uint64_t bak_entries = gpt_rd64(bak + 72);

	gpt_wr32(g->hdr + 88, table_crc);
	gpt_wr32(g->hdr + 16, 0);
	gpt_wr32(g->hdr + 16, gpt_crc32(g->hdr, 92));
	gpt_wr32(bak + 88, table_crc);
	gpt_wr32(bak + 16, 0);
	gpt_wr32(bak + 16, gpt_crc32(bak, 92));

	if (pwrite(fd, g->table, g->table_bytes, bak_entries * SECTOR) != (ssize_t)g->table_bytes ||
	    pwrite(fd, bak, SECTOR, backup_lba * SECTOR) != SECTOR || fsync(fd) != 0)
		return fail("cannot write the backup GPT");
	if (pwrite(fd, g->table, g->table_bytes, g->entries_lba * SECTOR) != (ssize_t)g->table_bytes ||
	    pwrite(fd, g->hdr, SECTOR, 1 * SECTOR) != SECTOR || fsync(fd) != 0)
		return fail("cannot write the primary GPT");
	return 0;
}

int main(int argc, char **argv) {
	if (argc < 3) {
		fprintf(stderr, "usage: gptslot <device> geometry|flip NAME...\n");
		return 2;
	}
	int flip = strcmp(argv[2], "flip") == 0;
	if (!flip && strcmp(argv[2], "geometry") != 0) return fail("unknown command");
	if (flip && argc < 4) return fail("flip needs at least one partition name");

	int fd = open(argv[1], flip ? O_RDWR : O_RDONLY);
	if (fd < 0) return fail("cannot open the device");

	struct gpt g;
	const char *err = gpt_read(fd, &g);
	if (err) return fail(err);

	struct slot s[NSLOTS];
	if (derive(&g, s) != 0) return fail("not a BaseOS A/B layout");

	if (!flip) {
		for (int i = 0; i < NSLOTS; i++)
			printf("SLOT_%s=%c\nSLOT_%s_SECTORS=%llu\n"
			       "SLOT_%s_ACTIVE=%llu\nSLOT_%s_INACTIVE=%llu\n",
			       UPPER[i], s[i].letter, UPPER[i], (unsigned long long)s[i].sectors,
			       UPPER[i], (unsigned long long)s[i].active,
			       UPPER[i], (unsigned long long)s[i].inactive);
		return 0;
	}

	for (int a = 3; a < argc; a++) {
		int i = 0;
		while (i < NSLOTS && strcmp(argv[a], NAMES[i]) != 0) i++;
		if (i == NSLOTS) return fail("not an A/B partition");
		uint8_t *e = gpt_entry(&g, s[i].idx);
		gpt_wr64(e + GPT_START, s[i].inactive);
		gpt_wr64(e + GPT_END, s[i].inactive + s[i].sectors - 1);
		printf("%s %c -> %c (start %llu)\n", NAMES[i], s[i].letter,
		       s[i].letter == 'A' ? 'B' : 'A', (unsigned long long)s[i].inactive);
	}
	return commit(fd, &g);
}
