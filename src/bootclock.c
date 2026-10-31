// Prints when, in seconds from power-on, the uptime clock started: the arch
// counter, which runs from SoC reset, minus CLOCK_MONOTONIC_RAW. Upstream
// BaseOS logs it as "before Linux"; added to a /run/boot-* mark, it puts that
// mark on the power-on clock. Constant for a boot until the first suspend.
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static uint64_t counter(void) {
	uint64_t v;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v) : : "memory");
	return v;
}

int main(void) {
	uint64_t freq;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
	if (!freq)
		return 1;
	// Bracketed: a preemption between the two reads would skew the offset.
	for (int i = 0; i < 16; i++) {
		struct timespec ts;
		uint64_t a = counter();
		clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
		uint64_t b = counter();
		if ((b - a) * 1000000 / freq > 100)
			continue;
		double at = (double)(a + (b - a) / 2) / (double)freq;
		printf("%.3f\n", at - (double)ts.tv_sec - ts.tv_nsec / 1e9);
		return 0;
	}
	return 1;
}
