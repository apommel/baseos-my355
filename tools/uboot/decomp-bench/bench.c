// Time U-Boot's own gunzip() and zstd_decompress() objects on the device;
// linked by build.sh.
// Usage: bench gzip|zstd FILE [reps]
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct abuf { void *data; size_t size; _Bool alloced; };  // include/abuf.h
int gunzip(void *dst, int dstlen, unsigned char *src, unsigned long *lenp);
int zstd_decompress(struct abuf *in, struct abuf *out);

void schedule(void) {}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	cpu_set_t one;
	FILE *f;
	size_t n, cap = 64u << 20;
	unsigned char *in, *out;
	int reps = argc > 3 ? atoi(argv[3]) : 5;
	double best = 1e9;

	CPU_ZERO(&one);
	CPU_SET(0, &one);
	sched_setaffinity(0, sizeof(one), &one);

	f = fopen(argv[2], "rb");
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	rewind(f);
	in = malloc(n);
	fread(in, 1, n, f);
	fclose(f);
	out = malloc(cap);
	memset(out, 0, cap);		// fault every page in before timing

	for (int r = 0; r < reps; r++) {
		unsigned long len = n;
		double t0 = now();
		int ret;

		if (!strcmp(argv[1], "gzip")) {
			ret = gunzip(out, cap, in, &len);
		} else {
			struct abuf ai = { in, n, 0 }, ao = { out, cap, 0 };
			ret = zstd_decompress(&ai, &ao);
			len = ret;
		}
		double dt = now() - t0;
		if (ret < 0) {
			printf("error %d\n", ret);
			return 1;
		}
		if (dt < best)
			best = dt;
		if (r == 0)
			printf("%s: %zu -> %lu bytes\n", argv[2], n, len);
	}
	printf("%s %s: best %.1f ms of %d\n", argv[1], argv[2], best * 1e3, reps);
	return 0;
}
