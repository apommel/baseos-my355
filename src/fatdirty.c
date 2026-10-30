// fatdirty DEVICE — prints vfat or exfat; 0 dirty, 1 clean, 2 neither, 3 dirty
// but in use. Only fsck clears a flag found at mount.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static unsigned le16(const uint8_t *p) { return p[0] | p[1] << 8; }
static int pow2(unsigned v) { return v && !(v & (v - 1)); }

int main(int argc, char **argv) {
	uint8_t b[512];
	if (argc != 2) return 2;
	int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (fd < 0 || pread(fd, b, sizeof b, 0) != sizeof b) return 2;
	if (b[510] != 0x55 || b[511] != 0xaa) return 2;

	const char *type;
	int dirty;
	if (!memcmp(b + 3, "EXFAT   ", 8)) {
		// VolumeFlags' VolumeDirty, which the kernel sets in this sector (fs/exfat).
		type = "exfat";
		dirty = le16(b + 106) & 2;
	} else {
		// Enough of the BPB to reject NTFS and unformatted cards.
		unsigned bps = le16(b + 11);
		if (bps < 512 || bps > 4096 || !pow2(bps) || !pow2(b[13]) || !le16(b + 14) ||
		    b[16] < 1 || b[16] > 2)
			return 2;
		// The FAT32 test and the flag's offset are the kernel's (fs/fat/inode.c).
		int fat32 = !le16(b + 22);
		if (fat32 && !(b[36] | b[37] | b[38] | b[39])) return 2;
		type = "vfat";
		dirty = b[fat32 ? 65 : 37] & 1;
	}
	puts(type);
	if (!dirty) return 1;
	// Fails while any filesystem holds the device, even lazily unmounted.
	return open(argv[1], O_RDONLY | O_EXCL | O_CLOEXEC) < 0 && errno == EBUSY ? 3 : 0;
}
