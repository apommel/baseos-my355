// pwrkeyd — power off cleanly when the power key is held for 2 s. frontend-session
// starts it while there is no frontend to read the key, and stops it before one
// starts: otherwise the only way off is holding the key longer, the PMIC's hard cut.
//
//   pwrkeyd &
//
// The key is the PMIC's input device by name: the lid's hall sensor reports
// KEY_POWER too.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <poll.h>
#include <linux/input.h>
#include <sys/ioctl.h>

#define KEY_DEVICE "rk805 pwrkey"
#define HOLD_MS 2000	// as U-Boot's charge mode asks to boot (the vendor's KEY_LONG_DOWN_MS)

static long long now_ms(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static int open_key(void) {
	char path[32], name[64];
	for (int i = 0; i < 32; i++) {
		snprintf(path, sizeof path, "/dev/input/event%d", i);
		int fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0) continue;
		memset(name, 0, sizeof name);
		if (ioctl(fd, EVIOCGNAME(sizeof name - 1), name) >= 0 &&
		    strcmp(name, KEY_DEVICE) == 0)
			return fd;
		close(fd);
	}
	return -1;
}

int main(void) {
	// Outlives frontend-session, which init respawns every few seconds.
	setsid();
	int fd = open_key();
	if (fd < 0) { fprintf(stderr, "pwrkeyd: no %s device\n", KEY_DEVICE); return 1; }

	struct input_event ev[8];
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	long long deadline = -1;	// while held: when the hold counts
	for (;;) {
		int timeout = -1;
		if (deadline >= 0) {
			long long left = deadline - now_ms();
			if (left <= 0) break;
			timeout = (int)left;
		}
		int r = poll(&pfd, 1, timeout);
		if (r < 0 && errno != EINTR) { perror("pwrkeyd: poll"); return 1; }
		if (r <= 0) continue;

		ssize_t n = read(fd, ev, sizeof ev);
		if (n < 0) {
			if (errno == EINTR) continue;
			perror("pwrkeyd: read");
			return 1;
		}
		for (size_t i = 0; i < (size_t)n / sizeof *ev; i++) {
			if (ev[i].type != EV_KEY || ev[i].code != KEY_POWER) continue;
			if (ev[i].value == 1) deadline = now_ms() + HOLD_MS;
			else if (ev[i].value == 0) deadline = -1;
		}
	}
	execl("/sbin/poweroff", "poweroff", (char *)0);
	perror("pwrkeyd: poweroff");
	return 1;
}
