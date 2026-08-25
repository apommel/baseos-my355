// gptgrow — grow a named GPT partition to fill the whole device.
//
//   gptgrow /dev/mmcblk1 primary
//
// Extends the partition's ending LBA to the last usable sector of the real
// device, rewrites both GPT copies (headers + entry tables, CRCs recomputed)
// and the protective MBR, then live-resizes the partition in the kernel.
// Exits 0 if it grew, 1 if it already fills the device, 2 on error.
//
// Derived from upstream-h700/tools/gptgrow.c, which hardcodes that port's GPT
// geometry (8 entries, first usable LBA 4). Here everything is read from the
// header, so it also works on the 128-entry table tools/mkgpt.py writes.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/blkpg.h>

#define SECTOR 512

// EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, mixed-endian as stored in an entry.
static const uint8_t MS_BASIC[16] = {
	0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
	0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7
};

static uint32_t crc32_tab[256];
static void crc32_init(void) {
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc32_tab[i] = c;
	}
}
static uint32_t crc32(const uint8_t *p, size_t n) {
	uint32_t c = 0xFFFFFFFFu;
	for (size_t i = 0; i < n; i++)
		c = crc32_tab[(c ^ p[i]) & 0xff] ^ (c >> 8);
	return c ^ 0xFFFFFFFFu;
}

static uint64_t rd64(const uint8_t *p) {
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
	return v;
}
static void wr64(uint8_t *p, uint64_t v) {
	for (int i = 0; i < 8; i++) { p[i] = v & 0xff; v >>= 8; }
}
static uint32_t rd32(const uint8_t *p) {
	return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void wr32(uint8_t *p, uint32_t v) {
	for (int i = 0; i < 4; i++) { p[i] = v & 0xff; v >>= 8; }
}

// Entry names are UTF-16LE; ours are ASCII.
static int name_is(const uint8_t *e, const char *want) {
	for (int i = 0; i < 36; i++) {
		uint16_t c = e[56 + i * 2] | ((uint16_t)e[56 + i * 2 + 1] << 8);
		if (c != (uint8_t)want[i]) return 0;
		if (!want[i]) return 1;
	}
	return 1;
}

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: gptgrow /dev/blk NAME\n"); return 2; }
	const char *want = argv[2];
	crc32_init();

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) { perror("open"); return 2; }

	off_t bytes = lseek(fd, 0, SEEK_END);
	if (bytes <= 0) { fprintf(stderr, "cannot size device\n"); return 2; }
	uint64_t total = (uint64_t)bytes / SECTOR;

	uint8_t hdr[SECTOR];
	if (pread(fd, hdr, SECTOR, 1 * SECTOR) != SECTOR) { perror("read gpt"); return 2; }
	if (memcmp(hdr, "EFI PART", 8) != 0) { fprintf(stderr, "no primary GPT\n"); return 2; }

	uint64_t entries_lba = rd64(hdr + 72);
	uint32_t n_entries = rd32(hdr + 80), esz = rd32(hdr + 84);
	if (n_entries == 0 || esz < 128) {
		fprintf(stderr, "unexpected GPT shape %u x %u\n", n_entries, esz);
		return 2;
	}
	size_t table_bytes = (size_t)n_entries * esz;
	uint64_t entry_sectors = (table_bytes + SECTOR - 1) / SECTOR;

	uint8_t table[128 * 128];   // the largest table mkgpt.py writes
	if (table_bytes > sizeof(table)) { fprintf(stderr, "GPT table too large\n"); return 2; }
	if (pread(fd, table, table_bytes, entries_lba * SECTOR) != (ssize_t)table_bytes) {
		perror("read entries"); return 2;
	}

	uint8_t *e = NULL;
	int pno = 0;
	for (uint32_t i = 0; i < n_entries; i++) {
		if (name_is(table + (size_t)i * esz, want)) {
			e = table + (size_t)i * esz;
			pno = (int)i + 1;
			break;
		}
	}
	if (!e) { fprintf(stderr, "no partition named %s\n", want); return 2; }
	// Refuse anything but a data partition: this tool exists to be followed
	// by a mkfs, and growing the wrong entry would be unrecoverable.
	if (memcmp(e, MS_BASIC, 16) != 0) {
		fprintf(stderr, "p%d (%s) is not an MS basic data partition\n", pno, want);
		return 2;
	}

	uint64_t backup_hdr_lba = total - 1;
	uint64_t backup_entries_lba = backup_hdr_lba - entry_sectors;
	uint64_t last_usable = backup_entries_lba - 1;
	uint64_t start = rd64(e + 32), cur_end = rd64(e + 40);

	if (cur_end >= last_usable) {
		printf("p%d already fills the device (end=%llu, last_usable=%llu)\n",
		       pno, (unsigned long long)cur_end, (unsigned long long)last_usable);
		return 1;
	}
	if (start >= last_usable) { fprintf(stderr, "partition start past device end\n"); return 2; }

	wr64(e + 40, last_usable);
	uint32_t table_crc = crc32(table, table_bytes);

	uint8_t out[SECTOR];
	for (int copy = 0; copy < 2; copy++) {
		memset(out, 0, SECTOR);
		memcpy(out, hdr, 92);
		wr32(out + 16, 0);  // header CRC placeholder
		if (copy == 0) {
			wr64(out + 24, 1); wr64(out + 32, backup_hdr_lba); wr64(out + 72, entries_lba);
		} else {
			wr64(out + 24, backup_hdr_lba); wr64(out + 32, 1); wr64(out + 72, backup_entries_lba);
		}
		wr64(out + 48, last_usable);
		wr32(out + 88, table_crc);
		wr32(out + 16, crc32(out, 92));
		uint64_t at = (copy == 0) ? 1 : backup_hdr_lba;
		if (pwrite(fd, out, SECTOR, at * SECTOR) != SECTOR) { perror("write hdr"); return 2; }
	}
	if (pwrite(fd, table, table_bytes, entries_lba * SECTOR) != (ssize_t)table_bytes) {
		perror("write pri entries"); return 2;
	}
	if (pwrite(fd, table, table_bytes, backup_entries_lba * SECTOR) != (ssize_t)table_bytes) {
		perror("write bak entries"); return 2;
	}

	uint8_t mbr[SECTOR];
	if (pread(fd, mbr, SECTOR, 0) == SECTOR) {
		uint32_t sz = total - 1 > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)(total - 1);
		wr32(mbr + 446 + 12, sz);
		pwrite(fd, mbr, SECTOR, 0);
	}
	fsync(fd);

	// Resize the partition in the kernel: a full table reread is refused while
	// a sibling (the mounted rootfs) is busy. ENOTTY on a regular file.
	struct blkpg_partition part;
	memset(&part, 0, sizeof(part));
	part.start = (long long)start * SECTOR;
	part.length = (long long)(last_usable - start + 1) * SECTOR;
	part.pno = pno;
	struct blkpg_ioctl_arg arg;
	memset(&arg, 0, sizeof(arg));
	arg.op = BLKPG_RESIZE_PARTITION;
	arg.datalen = sizeof(part);
	arg.data = &part;
	if (ioctl(fd, BLKPG, &arg) != 0)
		perror("BLKPG resize (kernel view unchanged)");

	close(fd);
	printf("p%d grown: end %llu -> %llu (device %llu sectors)\n",
	       pno, (unsigned long long)cur_end, (unsigned long long)last_usable,
	       (unsigned long long)total);
	return 0;
}
