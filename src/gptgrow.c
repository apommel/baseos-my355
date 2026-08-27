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
#include <stdio.h>
#include <sys/ioctl.h>
#include <linux/blkpg.h>

#include "gpt.h"

// EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, mixed-endian as stored in an entry.
static const uint8_t MS_BASIC[16] = {
	0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
	0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7
};

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: gptgrow /dev/blk NAME\n"); return 2; }
	const char *want = argv[2];

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) { perror("open"); return 2; }

	off_t bytes = lseek(fd, 0, SEEK_END);
	if (bytes <= 0) { fprintf(stderr, "cannot size device\n"); return 2; }
	uint64_t total = (uint64_t)bytes / SECTOR;

	struct gpt g;
	const char *err = gpt_read(fd, &g);
	if (err) { fprintf(stderr, "%s\n", err); return 2; }

	int idx = gpt_find(&g, want);
	if (idx < 0) { fprintf(stderr, "no partition named %s\n", want); return 2; }
	uint8_t *e = gpt_entry(&g, idx);
	int pno = idx + 1;
	// Refuse anything but a data partition: this tool exists to be followed
	// by a mkfs, and growing the wrong entry would be unrecoverable.
	if (memcmp(e, MS_BASIC, 16) != 0) {
		fprintf(stderr, "p%d (%s) is not an MS basic data partition\n", pno, want);
		return 2;
	}

	uint64_t backup_hdr_lba = total - 1;
	uint64_t backup_entries_lba = backup_hdr_lba - g.entry_sectors;
	uint64_t last_usable = backup_entries_lba - 1;
	uint64_t start = gpt_rd64(e + GPT_START), cur_end = gpt_rd64(e + GPT_END);

	if (cur_end >= last_usable) {
		printf("p%d already fills the device (end=%llu, last_usable=%llu)\n",
		       pno, (unsigned long long)cur_end, (unsigned long long)last_usable);
		return 1;
	}
	if (start >= last_usable) { fprintf(stderr, "partition start past device end\n"); return 2; }

	gpt_wr64(e + GPT_END, last_usable);
	uint32_t table_crc = gpt_crc32(g.table, g.table_bytes);

	uint8_t out[SECTOR];
	for (int copy = 0; copy < 2; copy++) {
		memset(out, 0, SECTOR);
		memcpy(out, g.hdr, 92);
		gpt_wr32(out + 16, 0);  // header CRC placeholder
		if (copy == 0) {
			gpt_wr64(out + 24, 1);
			gpt_wr64(out + 32, backup_hdr_lba);
			gpt_wr64(out + 72, g.entries_lba);
		} else {
			gpt_wr64(out + 24, backup_hdr_lba);
			gpt_wr64(out + 32, 1);
			gpt_wr64(out + 72, backup_entries_lba);
		}
		gpt_wr64(out + 48, last_usable);
		gpt_wr32(out + 88, table_crc);
		gpt_wr32(out + 16, gpt_crc32(out, 92));
		uint64_t at = (copy == 0) ? 1 : backup_hdr_lba;
		if (pwrite(fd, out, SECTOR, at * SECTOR) != SECTOR) { perror("write hdr"); return 2; }
	}
	if (pwrite(fd, g.table, g.table_bytes, g.entries_lba * SECTOR) != (ssize_t)g.table_bytes) {
		perror("write pri entries"); return 2;
	}
	if (pwrite(fd, g.table, g.table_bytes, backup_entries_lba * SECTOR) != (ssize_t)g.table_bytes) {
		perror("write bak entries"); return 2;
	}

	uint8_t mbr[SECTOR];
	if (pread(fd, mbr, SECTOR, 0) == SECTOR) {
		uint32_t sz = total - 1 > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)(total - 1);
		gpt_wr32(mbr + 446 + 12, sz);
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
