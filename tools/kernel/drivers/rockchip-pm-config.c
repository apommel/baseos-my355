// SPDX-License-Identifier: GPL-2.0-only
/*
 * RK3566 BL31 suspend configuration, from stock's rockchip,pm-rk3568 node:
 * sends the sleep mode, wake sources and Linux sleep state through
 * ROCKCHIP_SIP_SUSPEND_MODE. Mainline has no driver for it, and without it
 * BL31 suspends with its defaults. Adapted from zlyme (Zetarancio).
 *
 * Regulators stay with the regulator framework and the RK817 sleep pin with
 * rk8xx-core.
 */
#include <linux/arm-smccc.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/suspend.h>

#include <soc/rockchip/rockchip_sip.h>

#define SIP_SUSPEND_MODE_CONFIG		0x01
#define SIP_SUSPEND_WKUP_SOURCE		0x02
#define SIP_SUSPEND_DEBUG_ENABLE	0x05
#define SIP_SUSPEND_LINUX_PM_STATE	0x09

struct rockchip_pm_config {
	u32 mode;
	u32 wakeup;
};

static unsigned long rockchip_pm_smc(struct device *dev, const char *op,
				     u32 ctrl, u32 arg)
{
	struct arm_smccc_res res;

	arm_smccc_smc(ROCKCHIP_SIP_SUSPEND_MODE, ctrl, arg, 0, 0, 0, 0, 0, &res);
	if (res.a0)
		dev_err(dev, "%s 0x%x rejected: %ld\n", op, arg, (long)res.a0);
	else
		dev_dbg(dev, "%s 0x%x\n", op, arg);
	return res.a0;
}

static int rockchip_pm_config_apply(struct device *dev)
{
	struct rockchip_pm_config *cfg = dev_get_drvdata(dev);
	unsigned long err;

	err = rockchip_pm_smc(dev, "mode", SIP_SUSPEND_MODE_CONFIG, cfg->mode);
	err |= rockchip_pm_smc(dev, "wakeup", SIP_SUSPEND_WKUP_SOURCE,
			       cfg->wakeup);
	return err ? -EIO : 0;
}

/* Resent every time: BL31 picks the mode from the state being entered. */
static int rockchip_pm_config_prepare(struct device *dev)
{
	unsigned long err;

	err = rockchip_pm_smc(dev, "pm state", SIP_SUSPEND_LINUX_PM_STATE,
			      mem_sleep_current);
	return rockchip_pm_config_apply(dev) ?: (err ? -EIO : 0);
}

static const struct dev_pm_ops rockchip_pm_config_pm_ops = {
	.prepare = rockchip_pm_config_prepare,
};

static int rockchip_pm_config_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct rockchip_pm_config *cfg;
	u32 debug;

	if (arm_smccc_1_1_get_conduit() == SMCCC_CONDUIT_NONE)
		return dev_err_probe(dev, -ENODEV, "no SMCCC conduit\n");

	cfg = devm_kzalloc(dev, sizeof(*cfg), GFP_KERNEL);
	if (!cfg)
		return -ENOMEM;
	if (of_property_read_u32(dev->of_node, "rockchip,sleep-mode-config",
				 &cfg->mode) ||
	    of_property_read_u32(dev->of_node, "rockchip,wakeup-config",
				 &cfg->wakeup))
		return dev_err_probe(dev, -EINVAL, "no sleep mode or wakeup\n");
	platform_set_drvdata(pdev, cfg);

	if (!of_property_read_u32(dev->of_node, "rockchip,sleep-debug-en", &debug))
		rockchip_pm_smc(dev, "debug", SIP_SUSPEND_DEBUG_ENABLE, debug);

	/* A rejection stays bound: .prepare retries and fails that suspend. */
	rockchip_pm_config_apply(dev);
	return 0;
}

static const struct of_device_id rockchip_pm_config_of_match[] = {
	{ .compatible = "rockchip,pm-rk3568" },
	{ }
};

static struct platform_driver rockchip_pm_config_driver = {
	.probe = rockchip_pm_config_probe,
	.driver = {
		.name = "rockchip-pm-config",
		.of_match_table = rockchip_pm_config_of_match,
		.pm = pm_sleep_ptr(&rockchip_pm_config_pm_ops),
	},
};
builtin_platform_driver(rockchip_pm_config_driver);

MODULE_DESCRIPTION("Rockchip RK3568 BL31 suspend configuration");
MODULE_LICENSE("GPL");
