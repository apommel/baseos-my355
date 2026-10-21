// wifibtd — tell wifibt-power when Bluetooth comes on or goes off. NextUI's
// bt_init.sh never calls into BaseOS before it waits for hci0, so the chip
// cannot be powered from a hook; instead:
//
//   rtk_btusb loading (bt_init.sh start insmods it when absent)  -> want bt
//   the BT rfkill switch unblocked or added unblocked            -> want bt
//   the BT rfkill switch blocked (bt_init.sh stop)               -> release bt
//
// A block is only believed if it still holds 2 s later. hci0 registers into the
// global BT state, still blocked by the last bt_init.sh stop, and bt_init.sh
// unblocks it 0.5 s after its insmod: that block is a BT start, not a stop.
//
//   wifibtd &
//
// WiFi needs none of this: S36load_wifi_modules is called on both sides.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <linux/netlink.h>

#define HELPER "/usr/sbin/wifibt-power"
#define MODULE_ADD "add@/module/rtk_btusb"
#define BLOCK_SETTLE_S 2

// struct rfkill_event as this kernel (5.10) sends it: 8 bytes.
struct rfkill_ev {
	unsigned int idx;
	unsigned char type, op, soft, hard;
};
#define RFKILL_TYPE_BLUETOOTH 2
#define RFKILL_OP_ADD 0
#define RFKILL_OP_CHANGE 2

static void run(const char *what) {
	pid_t pid = fork();
	if (pid == 0) {
		execl(HELPER, HELPER, what, "bt", (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

// Whether rfkill switch `idx` is soft-blocked now; a switch that is gone went
// with its device, which counts as off.
static int still_blocked(unsigned int idx) {
	char path[48], c = '1';
	snprintf(path, sizeof path, "/sys/class/rfkill/rfkill%u/soft", idx);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return 1;
	if (read(fd, &c, 1) != 1) c = '1';
	close(fd);
	return c != '0';
}

int main(void) {
	int ue = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT);
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK, .nl_groups = 1 };
	if (ue < 0 || bind(ue, (struct sockaddr *)&sa, sizeof sa) < 0) {
		perror("wifibtd: uevent socket");
		return 1;
	}
	int rf = open("/dev/rfkill", O_RDONLY | O_CLOEXEC);
	if (rf < 0) {
		perror("wifibtd: /dev/rfkill");
		return 1;
	}

	struct pollfd fds[2] = { { ue, POLLIN, 0 }, { rf, POLLIN, 0 } };
	char buf[4096];
	for (;;) {
		if (poll(fds, 2, -1) < 0) {
			if (errno == EINTR) continue;
			return 1;
		}
		if (fds[0].revents & POLLIN) {
			ssize_t n = recv(ue, buf, sizeof buf - 1, 0);
			// The first string of a uevent is "action@devpath".
			if (n > 0) {
				buf[n] = 0;
				if (strcmp(buf, MODULE_ADD) == 0)
					run("want");
			}
		}
		if (fds[1].revents & POLLIN) {
			struct rfkill_ev ev;
			ssize_t n = read(rf, &ev, sizeof ev);
			if (n == (ssize_t)sizeof ev && ev.type == RFKILL_TYPE_BLUETOOTH) {
				if (ev.op == RFKILL_OP_CHANGE && !ev.soft)
					run("want");
				else if (ev.op == RFKILL_OP_CHANGE) {
					sleep(BLOCK_SETTLE_S);
					if (still_blocked(ev.idx))
						run("release");
				} else if (ev.op == RFKILL_OP_ADD && !ev.soft)
					run("want");
			}
		}
		if ((fds[0].revents | fds[1].revents) & (POLLERR | POLLHUP | POLLNVAL))
			return 1;
	}
}
