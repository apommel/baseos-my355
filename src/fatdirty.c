// fatdirty DEVICE — prints vfat or exfat (and, if dirty, the FATs' size in
// sectors); 0 dirty, 1 clean, 2 neither, 3 dirty but in use. Only fsck clears
// a flag found at mount.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static unsigned le16(const uint8_t *p) { return p[0] | p[1] << 8; }
static unsigned long le32(const uint8_t *p) {
	return p[0] | p[1] << 8 | (unsigned long)p[2] << 16 | (unsigned long)p[3] << 24;
}
static int pow2(unsigned v) { return v && !(v & (v - 1)); }

int main(int argc, char **argv) {
	uint8_t b[512];
	if (argc != 2) return 2;
	int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (fd < 0 || pread(fd, b, sizeof b, 0) != sizeof b) return 2;
	if (b[510] != 0x55 || b[511] != 0xaa) return 2;

	const char *type;
	unsigned long sectors;
	int dirty;
	if (!memcmp(b + 3, "EXFAT   ", 8)) {
		// VolumeFlags' VolumeDirty, which the kernel sets in this sector (fs/exfat).
		unsigned shift = b[108], fats = b[110];
		unsigned long fatsz = le32(b + 84);
		if (shift < 9 || shift > 12 || fats < 1 || fats > 2 || !fatsz) return 2;
		type = "exfat";
		dirty = le16(b + 106) & 2;
		sectors = fats * fatsz << (shift - 9);
	} else {
		// Enough of the BPB to reject NTFS and unformatted cards.
		unsigned bps = le16(b + 11);
		if (bps < 512 || bps > 4096 || !pow2(bps) || !pow2(b[13]) || !le16(b + 14) ||
		    b[16] < 1 || b[16] > 2)
			return 2;
		// The FAT32 test and the flag's offset are the kernel's (fs/fat/inode.c).
		unsigned long fatsz = le16(b + 22);
		int fat32 = !fatsz;
		if (fat32) fatsz = le32(b + 36);
		if (!fatsz) return 2;
		type = "vfat";
		dirty = b[fat32 ? 65 : 37] & 1;
		sectors = b[16] * fatsz * (bps / 512);
	}
	int rc = 1;
	// The O_EXCL open fails while any filesystem holds the device, even lazily
	// unmounted.
	if (dirty)
		rc = open(argv[1], O_RDONLY | O_EXCL | O_CLOEXEC) < 0 && errno == EBUSY ? 3 : 0;
	if (rc) puts(type);
	else printf("%s %lu\n", type, sectors);
	return rc;
}
