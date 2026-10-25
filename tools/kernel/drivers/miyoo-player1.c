// SPDX-License-Identifier: GPL-2.0
/*
 * MIYOO Player1: the Miyoo Flip's gamepad, as the stock miyoo_inputd presents
 * it through uinput, so stock-built software sees the same device: name, Xbox
 * 360 IDs, keys, axes and ranges.
 *
 * Buttons come from the gpio-keys-polled device (event0), whose keyboard codes
 * stay as on stock for keymon: the vendor's /dev/miyooio read those same pins.
 * The sticks come from the MCU on UART1, 9600 8N1, in frames FF YL XL YR XR FE.
 * Calibration takes the stock /userdata/joypad.config format through sysfs.
 */
#include <linux/input.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/serdev.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#define FRAME_START	0xff
#define FRAME_END	0xfe
#define FRAME_LEN	6

/* miyoo_inputd's values: its clamp, a dead zone of 1/8 and its report step. */
#define AXIS_MAX	32767
#define AXIS_CLAMP	32760
#define DEAD_ZONE	(AXIS_CLAMP >> 3)
#define REPORT_STEP	(AXIS_CLAMP >> 8)

/* event0 code -> Player1 event, in stock's "xbox pad layout". */
static const struct p1_map {
	u16 from;
	u16 type;
	u16 code;
	s16 value;
} p1_map[] = {
	{ KEY_LEFTCTRL,   EV_KEY, BTN_SOUTH,   1 },	/* b */
	{ KEY_SPACE,      EV_KEY, BTN_EAST,    1 },	/* a */
	{ KEY_LEFTSHIFT,  EV_KEY, BTN_WEST,    1 },	/* x, stock's BTN_Y */
	{ KEY_LEFTALT,    EV_KEY, BTN_NORTH,   1 },	/* y, stock's BTN_X */
	{ KEY_TAB,        EV_KEY, BTN_TL,      1 },
	{ KEY_BACKSPACE,  EV_KEY, BTN_TR,      1 },
	{ KEY_RIGHTCTRL,  EV_KEY, BTN_SELECT,  1 },
	{ KEY_ENTER,      EV_KEY, BTN_START,   1 },
	{ KEY_ESC,        EV_KEY, BTN_MODE,    1 },	/* menu */
	{ KEY_RIGHTALT,   EV_KEY, BTN_THUMBL,  1 },
	{ KEY_RIGHTSHIFT, EV_KEY, BTN_THUMBR,  1 },
	{ KEY_PAGEUP,     EV_ABS, ABS_Z,     255 },	/* l2 */
	{ KEY_PAGEDOWN,   EV_ABS, ABS_RZ,    255 },	/* r2 */
	{ KEY_UP,         EV_ABS, ABS_HAT0Y,  -1 },
	{ KEY_DOWN,       EV_ABS, ABS_HAT0Y,   1 },
	{ KEY_LEFT,       EV_ABS, ABS_HAT0X,  -1 },
	{ KEY_RIGHT,      EV_ABS, ABS_HAT0X,   1 },
};

struct p1_cal {
	int min, zero, max;
};

struct p1 {
	struct input_dev *input;
	struct input_handler handler;
	struct work_struct key_work;
	spinlock_t lock;		/* held, cal, raw */
	unsigned long held;		/* bit n: p1_map[n] pressed */
	struct p1_cal cal[2][2];	/* [left, right][x, y] */
	u8 raw[4];			/* YL XL YR XR */
	int last[4];			/* X Y RX RY, as last reported */
	u8 frame[FRAME_LEN];
	size_t len;
};

static const struct p1_cal p1_cal_default = { 85, 130, 200 };

static void p1_key_work(struct work_struct *work)
{
	struct p1 *p1 = container_of(work, struct p1, key_work);
	int hat_x = 0, hat_y = 0, z = 0, rz = 0;
	unsigned long held;
	int i;

	spin_lock_irq(&p1->lock);
	held = p1->held;
	spin_unlock_irq(&p1->lock);

	for (i = 0; i < ARRAY_SIZE(p1_map); i++) {
		const struct p1_map *m = &p1_map[i];
		bool on = held & BIT(i);

		if (m->type == EV_KEY)
			input_report_key(p1->input, m->code, on);
		else if (!on)
			continue;
		else if (m->code == ABS_HAT0X)
			hat_x += m->value;
		else if (m->code == ABS_HAT0Y)
			hat_y += m->value;
		else if (m->code == ABS_Z)
			z = m->value;
		else
			rz = m->value;
	}
	input_report_abs(p1->input, ABS_HAT0X, hat_x);
	input_report_abs(p1->input, ABS_HAT0Y, hat_y);
	input_report_abs(p1->input, ABS_Z, z);
	input_report_abs(p1->input, ABS_RZ, rz);
	input_sync(p1->input);
}

/* Called under event0's event_lock, so the report waits for the work. */
static void p1_event(struct input_handle *handle, unsigned int type,
		     unsigned int code, int value)
{
	struct p1 *p1 = handle->handler->private;
	unsigned long flags;
	int i;

	if (type != EV_KEY || value == 2)	/* event0 autorepeats */
		return;

	for (i = 0; i < ARRAY_SIZE(p1_map); i++) {
		if (p1_map[i].from != code)
			continue;
		spin_lock_irqsave(&p1->lock, flags);
		if (value)
			p1->held |= BIT(i);
		else
			p1->held &= ~BIT(i);
		spin_unlock_irqrestore(&p1->lock, flags);
		schedule_work(&p1->key_work);
		return;
	}
}

static bool p1_match(struct input_handler *handler, struct input_dev *dev)
{
	return dev->name && !strcmp(dev->name, "gpio-keys-polled");
}

static int p1_connect(struct input_handler *handler, struct input_dev *dev,
		      const struct input_device_id *id)
{
	struct input_handle *handle;
	int ret;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;

	handle->dev = dev;
	handle->handler = handler;
	handle->name = "miyoo-player1";

	ret = input_register_handle(handle);
	if (ret)
		goto err_free;
	ret = input_open_device(handle);
	if (ret)
		goto err_unregister;
	return 0;

err_unregister:
	input_unregister_handle(handle);
err_free:
	kfree(handle);
	return ret;
}

static void p1_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id p1_ids[] = {
	{ .flags = INPUT_DEVICE_ID_MATCH_EVBIT, .evbit = { BIT_MASK(EV_KEY) } },
	{ }
};

/* miyoo_inputd's pk_frame_to_axis_x/y. */
static int p1_axis(const struct p1_cal *cal, int raw)
{
	int v;

	if (raw > cal->zero)
		v = (raw - cal->zero) * AXIS_CLAMP / (cal->max - cal->zero);
	else if (raw < cal->zero)
		v = (raw - cal->zero) * AXIS_CLAMP / (cal->zero - cal->min);
	else
		return 0;
	return clamp(v, -AXIS_CLAMP, AXIS_CLAMP);
}

static void p1_report_stick(struct p1 *p1, int stick, int abs_x, int abs_y)
{
	int x, y, *last = &p1->last[stick * 2];
	unsigned long flags;

	spin_lock_irqsave(&p1->lock, flags);
	x = p1_axis(&p1->cal[stick][0], p1->raw[stick * 2 + 1]);
	y = p1_axis(&p1->cal[stick][1], p1->raw[stick * 2]);
	spin_unlock_irqrestore(&p1->lock, flags);

	if ((s64)x * x + (s64)y * y < (s64)DEAD_ZONE * DEAD_ZONE)
		x = y = 0;
	if (abs(x - last[0]) > REPORT_STEP) {
		input_report_abs(p1->input, abs_x, x);
		last[0] = x;
	}
	if (abs(y - last[1]) > REPORT_STEP) {
		input_report_abs(p1->input, abs_y, y);
		last[1] = y;
	}
}

static size_t p1_receive(struct serdev_device *serdev, const u8 *buf,
			 size_t count)
{
	struct p1 *p1 = serdev_device_get_drvdata(serdev);
	unsigned long flags;
	size_t i;

	for (i = 0; i < count; i++) {
		if (!p1->len && buf[i] != FRAME_START)
			continue;
		p1->frame[p1->len++] = buf[i];
		if (p1->len < FRAME_LEN)
			continue;
		p1->len = 0;
		if (p1->frame[FRAME_LEN - 1] != FRAME_END)
			continue;

		spin_lock_irqsave(&p1->lock, flags);
		memcpy(p1->raw, &p1->frame[1], sizeof(p1->raw));
		spin_unlock_irqrestore(&p1->lock, flags);
		p1_report_stick(p1, 0, ABS_X, ABS_Y);
		p1_report_stick(p1, 1, ABS_RX, ABS_RY);
		input_sync(p1->input);
	}
	return count;
}

static const struct serdev_device_ops p1_serdev_ops = {
	.receive_buf = p1_receive,
	.write_wakeup = serdev_device_write_wakeup,
};

/* The key=value file miyoo_inputd reads; a missing key keeps its default. */
static ssize_t p1_cal_store(struct device *dev, int stick, const char *buf,
			    size_t count)
{
	static const char * const keys[] = { "x_min", "x_zero", "x_max",
					     "y_min", "y_zero", "y_max" };
	struct p1 *p1 = dev_get_drvdata(dev);
	struct p1_cal cal[2] = { p1_cal_default, p1_cal_default };
	int *v = &cal[0].min;
	int i;

	for (i = 0; i < ARRAY_SIZE(keys); i++) {
		const char *p = strnstr(buf, keys[i], count);

		if (p && p[strlen(keys[i])] == '=')
			sscanf(p + strlen(keys[i]) + 1, "%d", &v[i]);
	}
	/* As miyoo_inputd: an axis with no travel on a side takes the defaults. */
	if (cal[0].max == cal[0].zero || cal[0].min == cal[0].zero ||
	    cal[1].max == cal[1].zero || cal[1].min == cal[1].zero)
		cal[0] = cal[1] = p1_cal_default;

	spin_lock_irq(&p1->lock);
	memcpy(p1->cal[stick], cal, sizeof(cal));
	spin_unlock_irq(&p1->lock);
	return count;
}

static ssize_t p1_cal_show(struct device *dev, int stick, char *buf)
{
	struct p1 *p1 = dev_get_drvdata(dev);
	struct p1_cal cal[2];

	spin_lock_irq(&p1->lock);
	memcpy(cal, p1->cal[stick], sizeof(cal));
	spin_unlock_irq(&p1->lock);
	return sysfs_emit(buf, "x_min=%d\nx_max=%d\ny_min=%d\ny_max=%d\nx_zero=%d\ny_zero=%d\n",
			  cal[0].min, cal[0].max, cal[1].min, cal[1].max,
			  cal[0].zero, cal[1].zero);
}

static ssize_t calibration_left_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	return p1_cal_show(dev, 0, buf);
}

static ssize_t calibration_left_store(struct device *dev,
				      struct device_attribute *attr,
				      const char *buf, size_t count)
{
	return p1_cal_store(dev, 0, buf, count);
}

static ssize_t calibration_right_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	return p1_cal_show(dev, 1, buf);
}

static ssize_t calibration_right_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	return p1_cal_store(dev, 1, buf, count);
}

/* The bytes a calibration tool used to read from /dev/ttyS1: XL YL XR YR. */
static ssize_t raw_show(struct device *dev, struct device_attribute *attr,
			char *buf)
{
	struct p1 *p1 = dev_get_drvdata(dev);
	u8 raw[4];

	spin_lock_irq(&p1->lock);
	memcpy(raw, p1->raw, sizeof(raw));
	spin_unlock_irq(&p1->lock);
	return sysfs_emit(buf, "%u %u %u %u\n", raw[1], raw[0], raw[3], raw[2]);
}

static DEVICE_ATTR_RW(calibration_left);
static DEVICE_ATTR_RW(calibration_right);
static DEVICE_ATTR_RO(raw);

static struct attribute *p1_attrs[] = {
	&dev_attr_calibration_left.attr,
	&dev_attr_calibration_right.attr,
	&dev_attr_raw.attr,
	NULL
};
ATTRIBUTE_GROUPS(p1);

static int p1_probe(struct serdev_device *serdev)
{
	struct device *dev = &serdev->dev;
	struct input_dev *input;
	struct p1 *p1;
	int i, ret;

	p1 = devm_kzalloc(dev, sizeof(*p1), GFP_KERNEL);
	if (!p1)
		return -ENOMEM;
	spin_lock_init(&p1->lock);
	INIT_WORK(&p1->key_work, p1_key_work);
	for (i = 0; i < 4; i++)
		p1->cal[i / 2][i % 2] = p1_cal_default;
	for (i = 0; i < 4; i++)
		p1->last[i] = -1;
	serdev_device_set_drvdata(serdev, p1);

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;
	p1->input = input;
	input->name = "MIYOO Player1";
	input->id.bustype = BUS_USB;
	input->id.vendor = 0x045e;
	input->id.product = 0x028e;
	input->id.version = 0x0114;

	for (i = 0; i < ARRAY_SIZE(p1_map); i++)
		if (p1_map[i].type == EV_KEY)
			input_set_capability(input, EV_KEY, p1_map[i].code);
	input_set_abs_params(input, ABS_X, -AXIS_MAX, AXIS_MAX, 0, 0);
	input_set_abs_params(input, ABS_Y, -AXIS_MAX, AXIS_MAX, 0, 0);
	input_set_abs_params(input, ABS_RX, -AXIS_MAX, AXIS_MAX, 0, 0);
	input_set_abs_params(input, ABS_RY, -AXIS_MAX, AXIS_MAX, 0, 0);
	input_set_abs_params(input, ABS_Z, 0, 255, 0, 0);
	input_set_abs_params(input, ABS_RZ, 0, 255, 0, 0);
	input_set_abs_params(input, ABS_HAT0X, -1, 1, 0, 0);
	input_set_abs_params(input, ABS_HAT0Y, -1, 1, 0, 0);
	/* Stock's uinput device declares it too. */
	input_set_capability(input, EV_SW, SW_TABLET_MODE);

	ret = input_register_device(input);
	if (ret)
		return ret;

	serdev_device_set_client_ops(serdev, &p1_serdev_ops);
	ret = devm_serdev_device_open(dev, serdev);
	if (ret)
		return ret;
	serdev_device_set_baudrate(serdev, 9600);
	serdev_device_set_flow_control(serdev, false);
	ret = serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);
	if (ret)
		return ret;

	p1->handler = (struct input_handler) {
		.private = p1,
		.event = p1_event,
		.match = p1_match,
		.connect = p1_connect,
		.disconnect = p1_disconnect,
		.name = "miyoo-player1",
		.id_table = p1_ids,
	};
	return input_register_handler(&p1->handler);
}

static void p1_remove(struct serdev_device *serdev)
{
	struct p1 *p1 = serdev_device_get_drvdata(serdev);

	input_unregister_handler(&p1->handler);
	cancel_work_sync(&p1->key_work);
}

static const struct of_device_id p1_of_match[] = {
	{ .compatible = "miyoo,player1-gamepad" },
	{ }
};
MODULE_DEVICE_TABLE(of, p1_of_match);

static struct serdev_device_driver p1_driver = {
	.driver = {
		.name = "miyoo-player1",
		.of_match_table = p1_of_match,
		.dev_groups = p1_groups,
	},
	.probe = p1_probe,
	.remove = p1_remove,
};

/*
 * Last, so the pad registers after every other input device as on stock,
 * where launch.sh moves event1 aside.
 */
static int __init p1_init(void)
{
	return serdev_device_driver_register(&p1_driver);
}
late_initcall_sync(p1_init);

static void __exit p1_exit(void)
{
	serdev_device_driver_unregister(&p1_driver);
}
module_exit(p1_exit);

MODULE_DESCRIPTION("Miyoo Flip gamepad, as stock's MIYOO Player1");
MODULE_LICENSE("GPL");
