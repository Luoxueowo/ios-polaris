/*
 * Polaris S3330 RMI4 raw probe and opt-in experimental HID on GPIO33/34.
 * Separate from the read-only GCC/GENI diagnostic and SM7150 SE7 driver.
 * Requires both Polaris/SDM845 ADT identities AND polaristouch=1. No PMIC,
 * GCC, SE14, reset, VDDIO or IRQ access. Only GPIO33/34 are configured.
 * Query8 length seen in the shim is 1: F12 Data1 presence/offset is NOT
 * established. polaristouchhid=1 treats 0x08 as an experimental candidate,
 * never as a proven firmware layout. Default polaristouch=1 remains raw-only.
 */
#if defined(ARM64_BOARD_CONFIG_POLARIS)
#include <sys/param.h>
#include <sys/systm.h>
#include <kern/clock.h>
#include <kern/thread.h>
#include <kern/sched_prim.h>
#include <machine/machine_routines.h>
#include <pexpert/pexpert.h>

extern void polaris_hid_touch(int finger, int down, int x, int y);
static bool polaris_touch_i2c_board(void) { return true; }
extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
extern kern_return_t thread_terminate(thread_t);

#define NORTH_PA       0x03900000u
#define SDA_CFG        (33u * 0x1000u)
#define SCL_CFG        (34u * 0x1000u)
#define IO_REG         4u
#define SDA           SDA_CFG
#define SCL           SCL_CFG
#define RESET_CFG     (99u * 0x1000u)
#define I2C_ADDR      0x20u
#define CFG_MASK      0x3ffu
#define IN_PULL_UP    (3u | (2u << 6))
#define OUT_LOW       ((2u << 6) | 0x200u)
#define MAX_READ      96u
#define MAX_FINGERS   10u
#define FINGER_BYTES  8u

static vm_offset_t pt_gpio;
static vm_offset_t pt_reset_gpio;
static uint32_t saved_sda_cfg, saved_scl_cfg, saved_sda_io, saved_scl_io;
static int pt_sleep_chan;
static bool pt_started;
static bool pt_hid_enabled;
static bool pt_reset_enabled;
static bool pt_down[MAX_FINGERS];
static int pt_x[MAX_FINGERS], pt_y[MAX_FINGERS];
static unsigned pt_fingers;

static uint32_t
pt_rd(uint32_t off)
{
	uint32_t v = *(volatile uint32_t *)(pt_gpio + off);
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static void
pt_wr(uint32_t off, uint32_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)(pt_gpio + off) = v;
	__asm__ volatile("dsb osh" ::: "memory");
}

static uint32_t
pt_reset_rd(unsigned off)
{
	uint32_t v = *(volatile uint32_t *)(pt_reset_gpio + off);
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}

static void
pt_reset_wr(unsigned off, uint32_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)(pt_reset_gpio + off) = v;
	__asm__ volatile("dsb osh" ::: "memory");
}

/* Drive low by latching zero BEFORE enabling output; release to input/pull-up.
 * Never actively drive high; preserve unrelated TLMM config bits. */
static void
pt_line(uint32_t cfg, bool release)
{
	uint32_t old = pt_rd(cfg);
	if (!release) {
		pt_wr(cfg + IO_REG, pt_rd(cfg + IO_REG) & ~2u);
	}
	pt_wr(cfg, (old & ~CFG_MASK) | (release ? IN_PULL_UP : OUT_LOW));
}

static bool
pt_high(uint32_t cfg)
{
	return (pt_rd(cfg + IO_REG) & 1u) != 0;
}

static bool
pt_clock(void)
{
	pt_line(SCL, true);
	/* At most 100 us of bounded clock stretch, never assume SCL rose. */
	for (unsigned i = 0; i < 20; ++i) {
		if (pt_high(SCL)) {
			delay(5);
			return true;
		}
		delay(5);
	}
	return false;
}

static void
pt_stop(void)
{
	pt_line(SDA, false);
	delay(5);
	(void)pt_clock();
	pt_line(SDA, true);
	delay(5);
}

static bool
pt_idle(void)
{
	pt_line(SDA, true);
	pt_line(SCL, true);
	delay(20);
	return pt_high(SDA) && pt_high(SCL);
}

static bool
pt_start(bool repeated)
{
	pt_line(SDA, true);
	if (!repeated) {
		if (!pt_idle()) {
			return false; /* stuck bus: do not report false ACK */
		}
	} else if (!pt_clock()) {
		return false;
	}
	if (!pt_high(SDA) || !pt_high(SCL)) {
		return false;
	}
	pt_line(SDA, false);
	delay(5);
	pt_line(SCL, false);
	delay(5);
	return true;
}

static unsigned pt_write_failure;

static bool
pt_write(uint8_t b)
{
	pt_write_failure = 0;
	for (int i = 7; i >= 0; --i) {
		pt_line(SDA, (b & (1u << i)) != 0);
		delay(3);
		if (!pt_clock()) {
			pt_write_failure = 1;
			return false;
		}
		pt_line(SCL, false);
		delay(3);
	}
	pt_line(SDA, true);
	delay(5);
	if (!pt_clock()) {
		pt_write_failure = 1;
		return false;
	}
	bool ack = !pt_high(SDA);
	pt_line(SCL, false);
	delay(5);
	if (!ack) pt_write_failure = 2;
	return ack;
}

static bool
pt_read_byte(uint8_t *out, bool ack)
{
	uint8_t b = 0;
	pt_line(SDA, true);
	for (unsigned i = 0; i < 8; ++i) {
		if (!pt_clock()) {
			return false;
		}
		b = (uint8_t)((b << 1) | (pt_high(SDA) ? 1u : 0u));
		pt_line(SCL, false);
		delay(3);
	}
	pt_line(SDA, !ack);
	delay(3);
	if (!pt_clock()) {
		return false;
	}
	pt_line(SCL, false);
	pt_line(SDA, true);
	*out = b;
	return true;
}

static unsigned pt_read_stage;
static unsigned pt_read_failure;

/* Shim-proven RMI4 protocol: write 0xff,page then STOP; address the
 * one-byte register and repeat-start for reading. Each transfer is capped.
 * STOP and released lines on every exit, including a failed ACK/clock. */
static bool
pt_read(uint16_t reg, uint8_t *buf, unsigned len)
{
	bool ok = false;
	pt_read_failure = 0;
	pt_read_stage = 1;
	if (!len || len > MAX_READ || !pt_start(false)) goto out;
	pt_read_stage = 2;
	if (!pt_write(I2C_ADDR << 1)) goto out;
	pt_read_stage = 3;
	if (!pt_write(0xff)) goto out;
	pt_read_stage = 4;
	if (!pt_write((uint8_t)(reg >> 8))) goto out;
	pt_stop();
	pt_read_stage = 5;
	if (!pt_start(false)) goto out;
	pt_read_stage = 6;
	if (!pt_write(I2C_ADDR << 1)) goto out;
	pt_read_stage = 7;
	if (!pt_write((uint8_t)reg)) goto out;
	pt_read_stage = 8;
	if (!pt_start(true)) goto out;
	pt_read_stage = 9;
	if (!pt_write((I2C_ADDR << 1) | 1u)) goto out;
	for (unsigned i = 0; i < len; ++i) {
		pt_read_stage = 10 + i;
		if (!pt_read_byte(&buf[i], i + 1 < len)) goto out;
	}
	ok = true;
out:
	pt_read_failure = pt_write_failure;
	pt_stop();
	pt_read_stage = ok ? 30 : pt_read_stage;
	if (!pt_idle()) {
		pt_read_stage = 31;
		return false;
	}
	return ok;
}

static void
pt_wait(unsigned ms)
{
	uint64_t deadline;
	clock_interval_to_deadline(ms, NSEC_PER_MSEC, &deadline);
	(void)assert_wait_deadline(&pt_sleep_chan, THREAD_UNINT, deadline);
	thread_block(THREAD_CONTINUE_NULL);
}

static void
pt_restore(void)
{
	/* Always disable outputs first, then restore exactly the prior latches
	 * and mux/configuration of the two I2C pins. No other pin is touched. */
	pt_line(SDA, true);
	pt_line(SCL, true);
	pt_wr(SDA + IO_REG, saved_sda_io);
	pt_wr(SCL + IO_REG, saved_scl_io);
	pt_wr(SDA, saved_sda_cfg);
	pt_wr(SCL, saved_scl_cfg);
}

/* Vendor DSX Query5 contains size-of-Query6 then Control0.. presence bits.
 * Each present Control below 23 occupies one address for this layout. */
static bool
pt_f12_fingers(uint8_t query_base, uint8_t ctrl_base, unsigned *count,
    uint8_t *report_mask)
{
	uint8_t q[32] = {0}, ctrl[2] = {0}, size = 0;
	unsigned offset = 0, ctrl28_offset = 0;
	if (!pt_read((uint16_t)(query_base + 4u), &size, 1) ||
	    size < 4 || size > sizeof(q)) {
		return false;
	}
	for (unsigned n = 0; n < size; n += MAX_READ) {
		unsigned chunk = size - n < MAX_READ ? size - n : MAX_READ;
		if (!pt_read((uint16_t)(query_base + 5u + n), q + n, chunk)) {
			return false;
		}
	}
	/* First Query5 byte is size-of-Query6, then Control0.. bits. */
	if (!(q[1 + 23 / 8] & (1u << (23 % 8)))) {
		return false;
	}
	for (unsigned n = 0; n < 23; ++n) {
		offset += (q[1 + n / 8] >> (n % 8)) & 1u;
	}
	if (offset > 0xffu - ctrl_base ||
	    !pt_read((uint16_t)(ctrl_base + offset), ctrl, sizeof(ctrl))) {
		return false;
	}
	printf("POLARIS HID: F12 Ctrl23 at 0x%02x = %02x %02x\n",
	    (unsigned)(ctrl_base + offset), ctrl[0], ctrl[1]);
	if (!(ctrl[0] & 1u) || ctrl[1] < 1 || ctrl[1] > MAX_FINGERS) {
		return false;
	}
	*count = ctrl[1];
	if (q[1 + 28 / 8] & (1u << (28 % 8))) {
		for (unsigned n = 0; n < 28; ++n) {
			ctrl28_offset += (q[1 + n / 8] >> (n % 8)) & 1u;
		}
		if (ctrl28_offset <= 0xffu - ctrl_base &&
		    pt_read((uint16_t)(ctrl_base + ctrl28_offset), report_mask, 1)) {
			printf("POLARIS HID: F12 Ctrl28 at 0x%02x report=0x%02x\n",
			    (unsigned)(ctrl_base + ctrl28_offset), *report_mask);
		}
	}
	return true;
}

/* Experimental: 0x08 is finger-correlated and the vendor driver's
 * zero-initialized Query8 fallback reads Data1 from the data base, but
 * Query8 length one does not independently establish its presence. */
static void
pt_release(void)
{
	for (unsigned i = 0; i < MAX_FINGERS; ++i) {
		if (pt_down[i]) {
			polaris_hid_touch((int)i, 0, pt_x[i], pt_y[i]);
			pt_down[i] = false;
		}
	}
}

static bool
pt_frame(const uint8_t *b, int *x, int *y, bool *present)
{
	*present = false;
	if ((b[0] & 0x0f) == 0) {
		return true;
	}
	/* Vendor S3330 DSX: object status, LE x/y, z, wx, wy.
	 * Reject unknown object types and out-of-panel coordinates. */
	*x = (int)((unsigned)b[1] | ((unsigned)b[2] << 8));
	*y = (int)((unsigned)b[3] | ((unsigned)b[4] << 8));
	if ((b[0] & 0x0f) != 1 || *x >= 1080 || *y >= 2160) {
		return false;
	}
	*present = true;
	return true;
}

static void
pt_thread(void *arg __unused, wait_result_t result __unused)
{
	uint8_t f01[6] = {0}, f12[6] = {0}, query[16] = {0};
	uint8_t raw[MAX_FINGERS * FINGER_BYTES] = {0};
	pt_gpio = ml_io_map(NORTH_PA, 0x23000);
	pt_reset_gpio = ml_io_map(NORTH_PA + RESET_CFG, 0x1000);
	if (!pt_gpio || !pt_reset_gpio) {
		printf("POLARIS I2C: TLMM north map failed\n");
		goto done;
	}
	saved_sda_cfg = pt_rd(SDA);
	saved_scl_cfg = pt_rd(SCL);
	saved_sda_io = pt_rd(SDA + IO_REG);
	saved_scl_io = pt_rd(SCL + IO_REG);
	printf("POLARIS I2C: RESET99 before cfg=0x%x io=0x%x\n",
	    pt_reset_rd(0), pt_reset_rd(IO_REG));
	if (pt_reset_enabled) {
		uint32_t cfg = pt_reset_rd(0);
		uint32_t io = pt_reset_rd(IO_REG);
		/* Only release an already asserted, GPIO-output active-low reset.
		 * No low pulse, no VIO23 or PMIC change. Leave it deasserted. */
		if ((cfg & CFG_MASK) != 0x201u || (io & 2u)) {
			printf("POLARIS I2C: RESET99 not asserted as expected; refusing reset release\n");
			goto restore;
		}
		pt_reset_wr(IO_REG, io | 2u);
		pt_wait(200);
		printf("POLARIS I2C: RESET99 released cfg=0x%x io=0x%x\n",
		    pt_reset_rd(0), pt_reset_rd(IO_REG));
		if (!(pt_reset_rd(IO_REG) & 1u)) {
			printf("POLARIS I2C: RESET99 pad did not rise\n");
			goto restore;
		}
	}
	/* Require a verified released bus after configuring GPIO33/34 open drain. */
	if (!pt_idle()) {
		printf("POLARIS I2C: bus stuck; no RMI4 transactions\n");
		goto restore;
	}
	if (!pt_read(0x00e3, f01, sizeof(f01))) {
		printf("POLARIS I2C: F01 PDT read failed stage=%u reason=%u (1=SCL,2=NACK) lines=%u%u\n",
		    pt_read_stage, pt_read_failure, pt_high(SDA), pt_high(SCL));
		goto restore;
	}
	printf("POLARIS I2C: F01 PDT %02x %02x %02x %02x %02x %02x\n",
	    f01[0], f01[1], f01[2], f01[3], f01[4], f01[5]);
	if (f01[0] != 0x2c || f01[1] != 0x23 || f01[2] != 0x0c ||
	    f01[3] != 0x06 || f01[5] != 0x01) {
		printf("POLARIS I2C: F01 PDT identity mismatch; HID withheld\n");
		goto restore;
	}
	if (!pt_read(0x00dd, f12, sizeof(f12))) {
		printf("POLARIS I2C: F12 PDT read failed stage=%u reason=%u lines=%u%u\n",
		    pt_read_stage, pt_read_failure, pt_high(SDA), pt_high(SCL));
		goto restore;
	}
	printf("POLARIS I2C: F12 PDT %02x %02x %02x %02x %02x %02x\n",
	    f12[0], f12[1], f12[2], f12[3], f12[4], f12[5]);
	if (f12[0] != 0x49 || f12[1] != 0x00 || f12[2] != 0x12 ||
	    f12[3] != 0x08 || f12[5] != 0x12) {
		printf("POLARIS I2C: F12 PDT identity mismatch; HID withheld\n");
		goto restore;
	}
	printf("POLARIS I2C: PDT F01 %02x %02x %02x %02x %02x %02x F12 %02x %02x %02x %02x %02x %02x\n",
	    f01[0], f01[1], f01[2], f01[3], f01[4], f01[5],
	    f12[0], f12[1], f12[2], f12[3], f12[4], f12[5]);
	uint8_t f01_status[2] = {0}, f01_ctrl = 0;
	if (!pt_read(f01[3], f01_status, sizeof(f01_status)) ||
	    !pt_read(f01[2], &f01_ctrl, 1)) {
		printf("POLARIS I2C: F01 status/control read failed stage=%u reason=%u\n",
		    pt_read_stage, pt_read_failure);
		goto restore;
	}
	printf("POLARIS I2C: F01 device=0x%02x irq=0x%02x control=0x%02x (configured=%u)\n",
	    f01_status[0], f01_status[1], f01_ctrl, (f01_ctrl >> 7) & 1u);
	if (!pt_read(f12[0], query, sizeof(query))) {
		printf("POLARIS I2C: F12 raw query read failed\n");
		goto restore;
	}
	printf("POLARIS I2C: F12 query+0..15 %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x; Query8 length=%u; HID layout UNPROVEN\n",
	    query[0], query[1], query[2], query[3], query[4], query[5], query[6], query[7],
	    query[8], query[9], query[10], query[11], query[12], query[13], query[14], query[15], query[7]);
	if (pt_hid_enabled && (query[0] != 3 || query[1] != 4 ||
	    query[2] != 0x26 || query[3] != 0xff || query[4] != 0x0f ||
	    query[5] != 0 || query[6] != 1 || query[7] != 1)) {
		printf("POLARIS HID: unknown F12 query signature; refusing HID\n");
		goto restore;
	}
	if (pt_hid_enabled) {
		pt_fingers = 1; /* shim-observed single slot only */
		unsigned reported = 0;
		uint8_t report_mask = 0;
		if (pt_f12_fingers(f12[0], f12[2], &reported, &report_mask)) {
			if (report_mask == 0xffu) {
				pt_fingers = reported;
				printf("POLARIS HID: Ctrl23 confirmed %u slots, 8-byte report\n", pt_fingers);
			} else {
				printf("POLARIS HID: Ctrl28 is not 8-byte report; refusing HID\n");
				goto restore;
			}
		} else {
			printf("POLARIS HID: Ctrl23 unverified; one experimental slot only\n");
		}
	}
	if (pt_hid_enabled) {
		unsigned failures = 0;
		bool logged_bad_frame = false;
		unsigned candidates[MAX_FINGERS] = {0};
		int prior_x[MAX_FINGERS] = {0}, prior_y[MAX_FINGERS] = {0};
		printf("POLARIS HID: experimental F12 base 0x%02x, %u slots, 8 bytes each\n",
		    f12[3], pt_fingers);
		for (;;) {
			bool valid = true, present[MAX_FINGERS] = {0};
			int x[MAX_FINGERS] = {0}, y[MAX_FINGERS] = {0};
			bool read_ok = pt_read(f12[3], raw, pt_fingers * FINGER_BYTES);
			unsigned bad_slot = MAX_FINGERS;
			if (read_ok) {
				for (unsigned slot = 0; slot < pt_fingers; ++slot) {
					if (!pt_frame(raw + slot * FINGER_BYTES,
					    &x[slot], &y[slot], &present[slot])) {
						valid = false;
						bad_slot = slot;
						break;
					}
				}
			} else {
				valid = false;
			}
			if (!valid && !logged_bad_frame) {
				printf("POLARIS HID: first invalid frame read=%u stage=%u reason=%u slot=%u first=%02x %02x %02x %02x %02x %02x %02x %02x\n",
				    read_ok, pt_read_stage, pt_read_failure, bad_slot,
				    raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7]);
				logged_bad_frame = true;
			}
			if (!valid) {
				pt_release();
				for (unsigned slot = 0; slot < pt_fingers; ++slot) candidates[slot] = 0;
				if (++failures >= 8) {
					printf("POLARIS HID: repeated read/invalid frames, stopping\n");
					break;
				}
				pt_wait(20);
				continue;
			}
			failures = 0;
			for (unsigned slot = 0; slot < pt_fingers; ++slot) {
				if (!present[slot]) {
					if (pt_down[slot]) {
						polaris_hid_touch((int)slot, 0, pt_x[slot], pt_y[slot]);
						pt_down[slot] = false;
					}
					candidates[slot] = 0;
					continue;
				}
				if (!pt_down[slot]) {
					if (candidates[slot] && x[slot] - prior_x[slot] < 80 &&
					    prior_x[slot] - x[slot] < 80 && y[slot] - prior_y[slot] < 80 &&
					    prior_y[slot] - y[slot] < 80) {
						polaris_hid_touch((int)slot, 1, x[slot], y[slot]);
						pt_down[slot] = true;
						pt_x[slot] = x[slot]; pt_y[slot] = y[slot];
						candidates[slot] = 0;
					} else {
						candidates[slot] = 1;
					}
					prior_x[slot] = x[slot]; prior_y[slot] = y[slot];
				} else if (x[slot] - pt_x[slot] >= 200 || pt_x[slot] - x[slot] >= 200 ||
				    y[slot] - pt_y[slot] >= 200 || pt_y[slot] - y[slot] >= 200) {
					polaris_hid_touch((int)slot, 0, pt_x[slot], pt_y[slot]);
					pt_down[slot] = false;
					candidates[slot] = 0;
				} else if (x[slot] != pt_x[slot] || y[slot] != pt_y[slot]) {
					polaris_hid_touch((int)slot, 1, x[slot], y[slot]);
					pt_x[slot] = x[slot]; pt_y[slot] = y[slot];
				}
			}
			pt_wait(20);
		}
	} else {
		for (unsigned i = 0; i < 4; ++i) {
			if (!pt_read(f12[3], raw, FINGER_BYTES)) {
				printf("POLARIS I2C: raw sample %u failed; stopping\n", i);
				goto restore;
			}
			printf("POLARIS I2C: raw 0x%02x sample %u: %02x %02x %02x %02x %02x %02x %02x %02x (NOT contacts)\n",
			    f12[3], i, raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7]);
			pt_wait(250);
		}
	}

restore:
	pt_release();
	pt_restore();
	printf("POLARIS I2C: stopped, GPIO33/34 restored\n");
done:
	(void)thread_terminate(current_thread());
	thread_block(THREAD_CONTINUE_NULL);
}

void
polaris_touch_i2c_init(void)
{
	int enabled = 0, hid_enabled = 0, reset_enabled = 0;
	thread_t thread;
	if (!polaris_touch_i2c_board()) {
		return;
	}
	(void)PE_parse_boot_argn("polaristouch", &enabled, sizeof(enabled));
	(void)PE_parse_boot_argn("polaristouchhid", &hid_enabled, sizeof(hid_enabled));
	(void)PE_parse_boot_argn("polaristouchreset", &reset_enabled, sizeof(reset_enabled));
	if ((enabled != 1 && hid_enabled != 1) || pt_started) {
		return;
	}
	pt_started = true;
	pt_hid_enabled = hid_enabled == 1;
	pt_reset_enabled = reset_enabled == 1;
	printf("POLARIS I2C: opted in; GPIO33/34 raw/PDT prototype; HID %s reset99 %s\n",
	    pt_hid_enabled ? "EXPERIMENTAL" : "off", pt_reset_enabled ? "release" : "unchanged");
	kern_return_t kr = kernel_thread_start(pt_thread, NULL, &thread);
	if (kr == KERN_SUCCESS) {
		thread_deallocate(thread);
	} else {
		printf("POLARIS I2C: thread start failed %d\n", kr);
	}
}
#endif
