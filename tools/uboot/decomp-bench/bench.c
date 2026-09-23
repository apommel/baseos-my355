// Time U-Boot's own decompressors on the device; linked by build.sh.
// Usage: bench gzip|zstd|lz4|lzma|lzo|bzip2 FILE [reps] [REFERENCE]
// With REFERENCE, the output is checked against it byte for byte.
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct abuf { void *data; size_t size; _Bool alloced; };  // include/abuf.h
int gunzip(void *dst, int dstlen, unsigned char *src, unsigned long *lenp);
int zstd_decompress(struct abuf *in, struct abuf *out);
int ulz4fn(const void *src, size_t srcn, void *dst, size_t *dstn);
int lzmaBuffToBuffDecompress(unsigned char *out, size_t *outlen,
			     const unsigned char *in, size_t inlen);
int lzop_decompress(const unsigned char *src, size_t src_len,
		    unsigned char *dst, size_t *dst_len);
int BZ2_bzBuffToBuffDecompress(char *dest, unsigned int *destLen, char *source,
			       unsigned int sourceLen, int small, int verbosity);

void schedule(void) {}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static unsigned char *slurp(const char *path, size_t *n)
{
	FILE *f = fopen(path, "rb");
	unsigned char *p;

	if (!f) {
		perror(path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	*n = ftell(f);
	rewind(f);
	p = malloc(*n);
	if (fread(p, 1, *n, f) != *n)
		exit(1);
	fclose(f);
	return p;
}

static long decode(const char *fmt, unsigned char *in, size_t n,
		   unsigned char *out, size_t cap)
{
	int ret = -1;

	if (!strcmp(fmt, "gzip")) {
		unsigned long len = n;
		ret = gunzip(out, cap, in, &len);
		return ret ? ret : (long)len;
	} else if (!strcmp(fmt, "zstd")) {
		struct abuf ai = { in, n, 0 }, ao = { out, cap, 0 };
		return zstd_decompress(&ai, &ao);
	}
	size_t len = cap;
	if (!strcmp(fmt, "lz4"))
		ret = ulz4fn(in, n, out, &len);
	else if (!strcmp(fmt, "lzma"))
		ret = lzmaBuffToBuffDecompress(out, &len, in, n);
	else if (!strcmp(fmt, "lzo"))
		ret = lzop_decompress(in, n, out, &len);
	else if (!strcmp(fmt, "bzip2")) {
		unsigned int l = cap;	// bootm's call: fast path, needs >4 MB malloc
		ret = BZ2_bzBuffToBuffDecompress((char *)out, &l, (char *)in, n, 0, 0);
		len = l;
	}
	return ret ? -abs(ret) - 1000 : (long)len;
}

int main(int argc, char **argv)
{
	cpu_set_t one;
	size_t n, refn = 0, cap = 64u << 20;
	unsigned char *in, *out, *ref = NULL;
	int reps = argc > 3 ? atoi(argv[3]) : 5;
	double best = 1e9;

	CPU_ZERO(&one);
	CPU_SET(0, &one);
	sched_setaffinity(0, sizeof(one), &one);

	in = slurp(argv[2], &n);
	if (argc > 4)
		ref = slurp(argv[4], &refn);
	out = malloc(cap);
	memset(out, 0, cap);		// fault every page in before timing

	for (int r = 0; r < reps; r++) {
		double t0 = now();
		long len = decode(argv[1], in, n, out, cap);
		double dt = now() - t0;

		if (len < 0) {
			printf("%s %s: error %ld\n", argv[1], argv[2], len);
			return 1;
		}
		if (ref && ((size_t)len != refn || memcmp(out, ref, refn))) {
			printf("%s %s: output differs from the reference\n", argv[1], argv[2]);
			return 1;
		}
		if (dt < best)
			best = dt;
	}
	printf("%s %s %zu: best %.1f ms of %d\n", argv[1], argv[2], n, best * 1e3, reps);
	return 0;
}
