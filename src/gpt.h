// Shared GPT primitives for the BaseOS partition tools (gptgrow, gptslot).
//
// Header-only and zero-dependency: both are built static into the rootfs.
// Table geometry is read from the header rather than assumed, so the tools do
// not encode the shape tools/mkgpt.py happens to write.
#ifndef BASEOS_GPT_H
#define BASEOS_GPT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define SECTOR 512
#define GPT_MAX_TABLE (128 * 128)   // the largest table mkgpt.py writes

#define GPT_START 32                // entry field offsets
#define GPT_END 40
#define GPT_NAME 56

struct gpt {
	uint8_t hdr[SECTOR];
	uint8_t table[GPT_MAX_TABLE];
	size_t table_bytes;
	uint32_t n_entries, esz;
	uint64_t entries_lba, entry_sectors;
};

static uint32_t gpt_crc32(const uint8_t *p, size_t n) {
	static uint32_t tab[256];
	static int ready;
	if (!ready) {
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t c = i;
			for (int k = 0; k < 8; k++)
				c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
			tab[i] = c;
		}
		ready = 1;
	}
	uint32_t c = 0xFFFFFFFFu;
	for (size_t i = 0; i < n; i++) c = tab[(c ^ p[i]) & 0xff] ^ (c >> 8);
	return c ^ 0xFFFFFFFFu;
}

static uint64_t gpt_rd64(const uint8_t *p) {
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
	return v;
}
static void gpt_wr64(uint8_t *p, uint64_t v) {
	for (int i = 0; i < 8; i++) { p[i] = v & 0xff; v >>= 8; }
}
static uint32_t gpt_rd32(const uint8_t *p) {
	return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void gpt_wr32(uint8_t *p, uint32_t v) {
	for (int i = 0; i < 4; i++) { p[i] = v & 0xff; v >>= 8; }
}

// Entry names are UTF-16LE; ours are ASCII.
static int gpt_name_is(const uint8_t *e, const char *want) {
	for (int i = 0; i < 36; i++) {
		uint16_t c = e[GPT_NAME + i * 2] | ((uint16_t)e[GPT_NAME + i * 2 + 1] << 8);
		if (c != (uint8_t)want[i]) return 0;
		if (!want[i]) return 1;
	}
	return 1;
}

static uint8_t *gpt_entry(struct gpt *g, int i) {
	return g->table + (size_t)i * g->esz;
}

// Index of the entry named `want`, or -1.
static int gpt_find(struct gpt *g, const char *want) {
	for (uint32_t i = 0; i < g->n_entries; i++)
		if (gpt_name_is(gpt_entry(g, (int)i), want)) return (int)i;
	return -1;
}

// Read the primary header and entry table. NULL on success, else the reason.
static const char *gpt_read(int fd, struct gpt *g) {
	if (pread(fd, g->hdr, SECTOR, 1 * SECTOR) != SECTOR) return "cannot read the GPT";
	if (memcmp(g->hdr, "EFI PART", 8) != 0) return "no primary GPT";
	g->entries_lba = gpt_rd64(g->hdr + 72);
	g->n_entries = gpt_rd32(g->hdr + 80);
	g->esz = gpt_rd32(g->hdr + 84);
	if (g->n_entries == 0 || g->esz < 128) return "unexpected GPT shape";
	g->table_bytes = (size_t)g->n_entries * g->esz;
	g->entry_sectors = (g->table_bytes + SECTOR - 1) / SECTOR;
	if (g->table_bytes > sizeof(g->table)) return "GPT table too large";
	if (pread(fd, g->table, g->table_bytes, g->entries_lba * SECTOR) !=
	    (ssize_t)g->table_bytes)
		return "cannot read the GPT entries";
	return NULL;
}

#endif /* BASEOS_GPT_H */
