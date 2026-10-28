// SPDX-License-Identifier: GPL-2.0-only
/*
 * RK3566 CPU voltage bin, as the vendor's rockchip_opp_select picks it: the
 * OTP's PVTM count, times 10, against rockchip,pvtm-voltage-sel.
 */

#include <linux/cpu.h>
#include <linux/init.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_opp.h>
#include <linux/slab.h>

#define PVTM_SCALE	10
/* The lowest voltage of any bin: a lower mbist-vmin floor changes nothing. */
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

static int rk_cpufreq_bin(struct device *dev, struct device_node *np)
{
	u32 pvtm, index, vmin, min, sel;
	int i, n, bin = -ENOENT, ret;

	ret = rk_cpufreq_read_cell(np, "pvtm", &pvtm);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (ret || !pvtm) {
		dev_info(dev, "no PVTM count, keeping the common table\n");
		return -ENOENT;
	}
	pvtm *= PVTM_SCALE;

	/* As for the vendor, an index past the table is no floor. */
	ret = rk_cpufreq_read_cell(np, "mbist-vmin", &index);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (!ret && index &&
	    !of_property_read_u32_index(np, "mbist-vmin", index - 1, &vmin) &&
	    vmin > BIN_MIN_UV) {
		dev_info(dev, "pvtm %u, mbist-vmin %u uV: keeping the common table\n",
			 pvtm, vmin);
		return -ENOENT;
	}

	n = of_property_count_u32_elems(np, "rockchip,pvtm-voltage-sel");
	for (i = 0; i + 3 <= n; i += 3) {
		of_property_read_u32_index(np, "rockchip,pvtm-voltage-sel", i, &min);
		of_property_read_u32_index(np, "rockchip,pvtm-voltage-sel", i + 2, &sel);
		if (pvtm >= min)
			bin = sel;
	}
	if (bin < 0)
		dev_info(dev, "pvtm %u matches no bin, keeping the common table\n", pvtm);
	else
		dev_info(dev, "pvtm %u: bin L%d\n", pvtm, bin);
	return bin;
}

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
	bin = rk_cpufreq_bin(&pdev->dev, np);
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
