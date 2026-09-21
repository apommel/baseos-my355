// rebootmode — restart with a reboot argument, which busybox's reboot cannot
// pass. The kernel's reboot-mode driver turns it into a flag U-Boot reads.
//
//   rebootmode charge
//
// Restarts at once: the caller has already stopped everything and unmounted.
#include <stdio.h>
#include <unistd.h>
#include <linux/reboot.h>
#include <sys/syscall.h>

int main(int argc, char **argv) {
	if (argc != 2) { fprintf(stderr, "usage: rebootmode MODE\n"); return 2; }
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, argv[1]);
	perror("reboot");
	return 1;
}
