// SPDX-License-Identifier: GPL-2.0
/*
 * Stands in for the vendor's rtk_btusb.ko, at the path NextUI's bt_init.sh
 * insmods: its loading is what tells BaseOS (wifibtd) to power the chip.
 * Bluetooth itself is mainline's btusb, loaded after 8733bu: the other order
 * resets the shared chip and takes wlan0 down.
 */
#include <linux/kmod.h>
#include <linux/module.h>

static int __init rtk_btusb_init(void)
{
	request_module("8733bu");
	request_module("btusb");
	return 0;
}
module_init(rtk_btusb_init);

static void __exit rtk_btusb_exit(void)
{
}
module_exit(rtk_btusb_exit);

MODULE_DESCRIPTION("Stock's rtk_btusb, loading mainline's btusb");
MODULE_LICENSE("GPL");
