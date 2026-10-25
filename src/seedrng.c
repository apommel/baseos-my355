// seedrng — credit the seed saved at the last shutdown to the kernel's pool.
// Mainline leaves the RK3566 TRNG off, so without this the crng is not ready
// until ~3 s and dbus-daemon blocks on it. Writing to /dev/urandom mixes but
// credits nothing; RNDADDENTROPY credits.
//
//   seedrng /data/random-seed
//
// The file is replaced before anything else, so a seed is never credited twice.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <linux/random.h>
#include <sys/ioctl.h>
#include <sys/random.h>

#define SEED_LEN 512

static int save(const char *path) {
	unsigned char buf[SEED_LEN];
	if (getrandom(buf, sizeof(buf), GRND_NONBLOCK) != sizeof(buf))
		return -1;	// pool not ready: a seed drawn now is not worth crediting
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return -1;
	int ok = write(fd, buf, sizeof(buf)) == sizeof(buf) && fsync(fd) == 0;
	close(fd);
	return ok ? 0 : -1;
}

int main(int argc, char **argv) {
	if (argc != 2) { fprintf(stderr, "usage: seedrng FILE\n"); return 2; }

	struct { struct rand_pool_info info; unsigned char buf[SEED_LEN]; } seed;
	int fd = open(argv[1], O_RDONLY);
	ssize_t n = fd < 0 ? -1 : read(fd, seed.buf, sizeof(seed.buf));
	if (fd >= 0) close(fd);
	// Unlinked first: if the credit lands but the rewrite fails, the next boot
	// finds no seed rather than this one again.
	unlink(argv[1]);
	sync();

	if (n == SEED_LEN) {
		int rnd = open("/dev/urandom", O_RDWR);
		seed.info.entropy_count = 256;	// enough to initialise the crng
		seed.info.buf_size = n;
		if (rnd < 0 || ioctl(rnd, RNDADDENTROPY, &seed) < 0)
			perror("seedrng: RNDADDENTROPY");
		if (rnd >= 0) close(rnd);
	}
	memset(&seed, 0, sizeof(seed));

	return save(argv[1]) == 0 ? 0 : 1;
}
