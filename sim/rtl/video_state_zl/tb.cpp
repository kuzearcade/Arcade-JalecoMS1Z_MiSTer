// MS1-Z line renderer against one MAME frame, from MAME's state dump
// (tools/mk_video_state_z.py). Real raster pacing: 8 clocks per pixel,
// 384 x 278, vtick at the last pixel of each line, exactly as ms1z_core.
#include "Vvs_zl_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
static std::vector<uint8_t> slurp(const std::string &p) {
	FILE *f = fopen(p.c_str(), "rb"); if (!f) { fprintf(stderr, "no %s\n", p.c_str()); exit(1); }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> v(n); if (n && fread(v.data(), 1, n, f) != (size_t)n) exit(1); fclose(f); return v;
}
static uint16_t rd16(const std::vector<uint8_t> &v, size_t w) { size_t b = w * 2; return b + 1 < v.size() ? v[b] | (v[b+1] << 8) : 0; }
static uint8_t rd8(const std::vector<uint8_t> &v, size_t b) { return b < v.size() ? v[b] : 0xFF; }
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::string d = argv[1];
	auto l0v = slurp(d + "/l0.vram"), l1v = slurp(d + "/l1.vram"), g0 = slurp(d + "/gfx0.bin"),
	     g1 = slurp(d + "/gfx1.bin"), spr = slurp(d + "/spriteram.bin"), srom = slurp(d + "/sprites.bin"),
	     pal = slurp(d + "/palette.bin"), exp = slurp(d + "/expected.raw");
	Vvs_zl_top *t = new Vvs_zl_top;
	{ FILE *f = fopen((d + "/regs.txt").c_str(), "r"); char k[64], v[64];
	  while (fscanf(f, "%63s %63s", k, v) == 2) { unsigned x = strtol(v, nullptr, 16);
	    if (!strcmp(k,"t0_sx")) t->t0_sx = x; if (!strcmp(k,"t0_sy")) t->t0_sy = x; if (!strcmp(k,"t0_ctrl")) t->t0_ctrl = x;
	    if (!strcmp(k,"t1_sx")) t->t1_sx = x; if (!strcmp(k,"t1_sy")) t->t1_sy = x; if (!strcmp(k,"t1_ctrl")) t->t1_ctrl = x;
	    if (!strcmp(k,"screen_flag")) t->screen_flag = x; } fclose(f); }
	int first_row = 0; if (FILE *f = fopen((d + "/first_row.txt").c_str(), "r")) { if (fscanf(f, "%d", &first_row) != 1) first_row = 0; fclose(f); }
	uint16_t spr_q = 0;
	auto serve = [&]() {
		t->l0_vram_data = rd16(l0v, t->l0_vram_addr); t->l1_vram_data = rd16(l1v, t->l1_vram_addr);
		t->l0_rom_data = rd8(g0, t->l0_rom_addr); t->l1_rom_data = rd8(g1, t->l1_rom_addr);
		t->spr_rom_data = rd8(srom, t->spr_rom_addr); t->pal_data = rd16(pal, t->pal_addr);
		t->spr_rq = spr_q; t->eval();
	};
	auto tick = [&]() {
		uint16_t nq = rd16(spr, t->spr_ra);        // registered read, as wram_sp
		t->clk = 0; t->eval(); serve(); t->clk = 1; t->eval(); spr_q = nq; serve();
	};
	t->reset = 1; for (int i = 0; i < 8; i++) tick(); t->reset = 0;
	std::vector<uint32_t> got(256 * 224, 0);
	// two whole frames; collect the second
	for (int fr = 0; fr < 2; fr++) {
		size_t p = 0;
		for (int v = 0; v < 278; v++) for (int h = 0; h < 384; h++) for (int c = 0; c < 8; c++) {
			t->hcount = h; t->vcount = v; t->vvalid = (h < 256 && v >= 16 && v < 240);
			t->ce = (c == 0); t->vtick = (c == 0 && h == 383);
			tick();
			if (fr == 1 && t->ce && t->rgb_valid && p < got.size()) got[p++] = t->rgb & 0xFFFFFF;
		}
	}
	const uint32_t *e32 = (const uint32_t *)exp.data(); int diff = 0, nb = 0;
	for (int i = first_row * 256; i < 256 * 224; i++) { if (e32[i] & 0xFFFFFF) nb++; if ((e32[i] & 0xFFFFFF) != got[i]) diff++; }
	printf("frame: rows %d..223, %d non-blank (MAME), %d differing pixels  %s  (overruns %u, max hits/line %u, max clocks/line %u)\n",
	       first_row, nb, diff, diff ? "DIFFERS" : "MATCH", t->overruns, t->max_hits, t->max_cycles);
	return diff ? 2 : 0;
}
