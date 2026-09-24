// fatdirty DEVICE — exit 0 if the FAT's dirty flag is set, printing the size of
// its FATs in 512-byte sectors; 1 if clean; 2 if not FAT or unreadable.
// Linux never clears a flag it found set at mount, only fsck does.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
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

	// Enough of the BPB to reject exFAT, NTFS and unformatted cards.
	unsigned bps = le16(b + 11);
	if (b[510] != 0x55 || b[511] != 0xaa || bps < 512 || bps > 4096 || !pow2(bps) ||
	    !pow2(b[13]) || !le16(b + 14) || b[16] < 1 || b[16] > 2)
		return 2;

	// The FAT32 test and the flag's offset are the kernel's (fs/fat/inode.c).
	unsigned long fatsz = le16(b + 22);
	int fat32 = !fatsz;
	if (fat32) fatsz = le32(b + 36);
	if (!fatsz) return 2;
	if (!(b[fat32 ? 65 : 37] & 1)) return 1;
	printf("%lu\n", b[16] * fatsz * (bps / 512));
	return 0;
}
