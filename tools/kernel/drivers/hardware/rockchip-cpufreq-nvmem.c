// SPDX-License-Identifier: GPL-2.0-only
/*
 * RK3566 voltage bins, as the vendor's rockchip_opp_select picks them from the
 * OTP. Also used by rk3568-dmc for vdd_logic.
 */

#include <linux/cpu.h>
#include <linux/init.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_opp.h>
#include <linux/slab.h>

#define PVTM_SCALE	10
/* No bin goes lower, so an mbist-vmin floor up to it changes nothing. */
#define BIN_MIN_UV	850000

static int rk_cpufreq_read_cell(struct device_node *np, const char *name,
				u32 *val)
{
	struct nvmem_cell *cell;
	size_t len;
	u8 *buf;
	int i;

	cell = of_nvmem_cell_get(np, name);
	if (IS_ERR(cell))
		return PTR_ERR(cell);
	buf = nvmem_cell_read(cell, &len);
	nvmem_cell_put(cell);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	*val = 0;
	for (i = min_t(int, len, sizeof(*val)) - 1; i >= 0; i--)
		*val = *val << 8 | buf[i];
	kfree(buf);
	return 0;
}

static int rk_opp_sel(struct device_node *np, const char *prop, u32 value)
{
	int i, n, bin = -ENOENT;
	u32 min, sel;

	n = of_property_count_u32_elems(np, prop);
	for (i = 0; i + 3 <= n; i += 3) {
		of_property_read_u32_index(np, prop, i, &min);
		of_property_read_u32_index(np, prop, i + 2, &sel);
		if (value >= min)
			bin = sel;
	}
	return bin;
}

/* Also called by rk3568-dmc. The higher of the PVTM and leakage bins. */
int rockchip_opp_bin(struct device *dev, struct device_node *np);
int rockchip_opp_bin(struct device *dev, struct device_node *np)
{
	u32 pvtm = 0, leakage, index, vmin;
	int ret, bin = -ENOENT;

	ret = rk_cpufreq_read_cell(np, "pvtm", &pvtm);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (!ret && pvtm)
		bin = rk_opp_sel(np, "rockchip,pvtm-voltage-sel", pvtm * PVTM_SCALE);

	ret = rk_cpufreq_read_cell(np, "leakage", &leakage);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (!ret)
		bin = max(bin, rk_opp_sel(np, "rockchip,leakage-voltage-sel", leakage));

	/* As for the vendor, an index past the table is no floor. */
	ret = rk_cpufreq_read_cell(np, "mbist-vmin", &index);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (!ret && index &&
	    !of_property_read_u32_index(np, "mbist-vmin", index - 1, &vmin) &&
	    vmin > BIN_MIN_UV)
		bin = -ENOENT;

	if (bin < 0)
		dev_info(dev, "pvtm %u: keeping the common table\n", pvtm * PVTM_SCALE);
	else
		dev_info(dev, "pvtm %u: bin L%d\n", pvtm * PVTM_SCALE, bin);
	return bin;
}
EXPORT_SYMBOL_GPL(rockchip_opp_bin);

static int rk_cpufreq_probe(struct platform_device *pdev)
{
	struct dev_pm_opp_config config = {};
	struct platform_device *dt_pdev;
	struct device_node *np;
	char name[] = "LXXXXXXXXXXX";
	unsigned int cpu;
	int bin, ret;

	np = dev_pm_opp_of_get_opp_desc_node(get_cpu_device(0));
	if (!np)
		return -ENOENT;
	bin = rockchip_opp_bin(&pdev->dev, np);
	of_node_put(np);
	if (bin == -EPROBE_DEFER)
		return bin;

	if (bin >= 0) {
		snprintf(name, sizeof(name), "L%d", bin);
		config.prop_name = name;
		for_each_present_cpu(cpu) {
			ret = dev_pm_opp_set_config(get_cpu_device(cpu), &config);
			if (ret < 0)
				return ret;
		}
	}

	dt_pdev = platform_device_register_simple("cpufreq-dt", -1, NULL, 0);
	return PTR_ERR_OR_ZERO(dt_pdev);
}

static struct platform_driver rk_cpufreq_driver = {
	.probe = rk_cpufreq_probe,
	.driver = {
		.name = "rockchip-cpufreq-nvmem",
	},
};

static int __init rk_cpufreq_init(void)
{
	struct platform_device *pdev;
	int ret;

	if (!of_machine_is_compatible("rockchip,rk3566"))
		return -ENODEV;

	ret = platform_driver_register(&rk_cpufreq_driver);
	if (ret)
		return ret;
	pdev = platform_device_register_simple("rockchip-cpufreq-nvmem", -1, NULL, 0);
	if (IS_ERR(pdev)) {
		platform_driver_unregister(&rk_cpufreq_driver);
		return PTR_ERR(pdev);
	}
	return 0;
}
device_initcall(rk_cpufreq_init);
