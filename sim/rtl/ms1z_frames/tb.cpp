// Mega System 1-Z reference simulation: the whole board from reset, ROMs
// served from zero-latency arrays.
//
//   ./obj_dir/Vms1z_core <imgdir> <frames> [dsw1 dsw2]
//
// <imgdir> is what tools/mk_ms1z_images.py writes. Every frame's summary
// line reports the counters the gates are built on; MS1_PPM=<n,n,...> dumps
// those frames as PPM, MS1_FRAMEDIR=<dir> writes every frame raw (256x224x3)
// for tools/frame_compare.py, MS1_WAV=<file> writes the mono mix (48 kHz,
// s16), MS1_BUSLOG=<file> the Z80 bus, MS1_TRLOG=<file> the 68000 trace.
#include "Vms1z_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <set>
#include <algorithm>

static std::vector<uint8_t> slurp(const std::string &p) {
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(1); }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> v(n);
	if (n && fread(v.data(), 1, n, f) != (size_t)n) exit(1);
	fclose(f); return v;
}
static uint8_t rd8(const std::vector<uint8_t> &v, size_t i) { return i < v.size() ? v[i] : 0xFF; }
static long envl(const char *n, long d) { const char *v = getenv(n); return v ? strtol(v, nullptr, 0) : d; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: %s imgdir frames [dsw1 dsw2]\n", argv[0]); return 1; }
	std::string d = argv[1];
	long nframes = atol(argv[2]);
	auto rom = slurp(d + "/maincpu.bin");
	auto zro = slurp(d + "/audiocpu.bin");
	auto g0  = slurp(d + "/gfx0.bin");
	auto g1  = slurp(d + "/gfx1.bin");
	auto spr = slurp(d + "/sprites.bin");

	Vms1z_core *top = new Vms1z_core;
	// MAME's DIP defaults: DSW1 0xBF (3 lives, Easy, upright, no flip),
	// DSW2 0xBF (1C1C / 1C1C, demo sounds ON, invulnerability off).
	top->in_dsw1 = argc > 3 ? strtol(argv[3], nullptr, 16) : 0xBF;
	top->in_dsw2 = argc > 4 ? strtol(argv[4], nullptr, 16) : 0xBF;
	top->in_p1 = 0xFF; top->in_p2 = 0xFF; top->in_system = 0xFF;
	top->pause = 0; top->osd_flip = 0;
	top->hs_addr = 0; top->hs_din = 0; top->hs_write = 0; top->hs_access = 0;
	top->rom_ready = 1; top->l0_rom_ready = 1; top->l1_rom_ready = 1; top->spr_rom_ready = 1;
	top->ss_freeze = 0; top->ss_resume = 0; top->ss_active = 0; top->ss_addr = 0;
	top->ss_wr = 0; top->ss_wdata = 0; top->ss_replay = 0;
	top->zrom_we = 0; top->reset = 1; top->clk = 0;

	auto serve = [&]() {
		unsigned ra = top->rom_addr * 2;
		top->rom_data = (rd8(rom, ra) << 8) | rd8(rom, ra + 1);
		top->l0_rom_data  = rd8(g0, top->l0_rom_addr);
		top->l1_rom_data  = rd8(g1, top->l1_rom_addr);
		top->spr_rom_data = rd8(spr, top->spr_rom_addr);
		top->eval();
	};
	auto tick = [&]() { top->clk = 0; top->eval(); serve(); top->clk = 1; top->eval(); serve(); };

	// The Z80 window streams in during reset, the way the download does.
	for (int i = 0; i < 16384; i++) {
		top->zrom_we = 1; top->zrom_waddr = i; top->zrom_wdata = rd8(zro, i); tick();
	}
	top->zrom_we = 0;
	for (int i = 0; i < 64; i++) tick();
	top->reset = 0;

	std::set<long> ppm;
	if (const char *p = getenv("MS1_PPM")) { std::string s = p; size_t a = 0;
		while (a < s.size()) { size_t b = s.find(',', a); if (b == std::string::npos) b = s.size();
			ppm.insert(atol(s.substr(a, b - a).c_str())); a = b + 1; } }
	const char *framedir = getenv("MS1_FRAMEDIR");
	FILE *wav = getenv("MS1_WAV") ? fopen(getenv("MS1_WAV"), "wb") : nullptr;
	// The two halves of the YM2203 on the SAME scale as the mix (the core
	// outputs (fm + {psg,5'd0}) >>> 1), for the per-source audio gate: FM is
	// fm >>> 1, SSG is psg << 4 (unsigned, as jt12_top adds it).
	FILE *wfm  = getenv("MS1_WAV_FM")  ? fopen(getenv("MS1_WAV_FM"),  "wb") : nullptr;
	FILE *wssg = getenv("MS1_WAV_SSG") ? fopen(getenv("MS1_WAV_SSG"), "wb") : nullptr;
	FILE *bus = getenv("MS1_BUSLOG") ? fopen(getenv("MS1_BUSLOG"), "w") : nullptr;
	long busn = envl("MS1_BUSN", 200000);
	FILE *trl = getenv("MS1_TRLOG") ? fopen(getenv("MS1_TRLOG"), "w") : nullptr;
	long trn = envl("MS1_TRN", 2000000);
	long every = envl("MS1_EVERY", 1);

	// ---------------------------------------------------------- savestate
	// MS1_SS_AT=<frame>: at that frame's vblank, run the engine's sequence --
	// park on the vblank edge (as rtl/savestate/savestate.sv's S_ARM does;
	// parking at an arbitrary tick is how MS1-61 hid), stream the image out,
	// stream it back in, replay the YM shadow, release -- and keep going.
	// With MS1_SS_LOOP=1 the core instead runs MS1_SS_SPAN frames, is
	// restored to the saved image, and runs the same frames again, and the
	// two spans are compared pixel for pixel (the round-trip gate).
	const long ss_at = envl("MS1_SS_AT", -1);
	const long SS_WORDS = 0x30000;
	std::vector<uint16_t> img(SS_WORDS, 0);
	auto park = [&]() {
		long g = 0;
		while (!top->vblank_rise && g++ < 4000000) tick();
		top->ss_freeze = 1; g = 0;
		while (!top->ss_frozen && g++ < 20000000) tick();
		printf("  ss: frozen=%d after %ld ticks\n", top->ss_frozen, g);
	};
	auto release = [&]() {
		top->ss_resume = 1; long g = 0;
		while (top->ss_parked && g++ < 20000000) tick();
		top->ss_freeze = 0;
		for (int i = 0; i < 64; i++) tick();
		top->ss_resume = 0;
		printf("  ss: released after %ld ticks\n", g);
	};
	auto stream_out = [&]() {
		top->ss_active = 1;
		for (long i = 0; i < SS_WORDS; i++) { top->ss_addr = i; tick(); tick(); tick(); img[i] = top->ss_rdata; }
		top->ss_active = 0;
		long nz = 0, ym = 0; for (long i = 0; i < SS_WORDS; i++) if (img[i]) nz++;
		for (long i = 0x1E000; i < 0x1E080; i++) ym += (img[i] & 0xFF ? 1 : 0) + (img[i] >> 8 ? 1 : 0);
		printf("  ss: image %ld non-zero words; YM shadow %ld/256 registers non-zero; ym_div %u sel %02X\n",
		       nz, ym, (img[0x1D021] >> 8) & 3, img[0x1D021] & 0xFF);
	};
	auto stream_in = [&]() {
		top->ss_active = 1;
		for (long i = 0; i < SS_WORDS; i++) {
			top->ss_addr = i; top->ss_wdata = img[i]; top->ss_wr = 1; tick(); top->ss_wr = 0; tick();
		}
		top->ss_active = 0;
		top->ss_replay = 1; long g = 0;
		while (!top->ss_replay_done && g++ < 5000000) tick();
		printf("  ss: replay %s after %ld ticks\n", top->ss_replay_done ? "done" : "TIMED OUT", g);
		top->ss_replay = 0; tick();
	};

	const long wlog_from = envl("MS1_WLOG", -1);
	int npal = 0, pal_lo = 999, pal_hi = -1, nscr = 0, scr_lo = 999, scr_hi = -1;
	const int W = 256, H = 224;
	std::vector<uint8_t> fb(W * H * 3, 0);
	std::vector<uint16_t> ib(W * H, 0);   // palette indices, MS1_IDX=1
	size_t p = 0;
	long frame = 0, acc = 0;
	unsigned ym0 = 0, lr0 = 0, sl0 = 0, i1 = 0, i2 = 0, i3 = 0;
	bool zacc_d = false;
	long ticks_total = 0;
	while (frame < nframes) {
		tick(); ticks_total++;
		if (top->ce_pix_o && top->rgb_valid && p < (size_t)W * H) {
			uint32_t c = top->rgb;
			fb[p*3] = c >> 16; fb[p*3+1] = c >> 8; fb[p*3+2] = c; ib[p] = top->dbg_pal_idx; p++;
		}
		if ((wav || wfm || wssg) && ++acc >= 1000) {
			acc = 0;
			if (wav)  { int16_t s = (int16_t)top->snd; fwrite(&s, 2, 1, wav); }
			if (wfm)  { int16_t s = (int16_t)((int16_t)top->dbg_fm_snd >> 1); fwrite(&s, 2, 1, wfm); }
			if (wssg) { int16_t s = (int16_t)(top->dbg_psg_snd << 4); fwrite(&s, 2, 1, wssg); }
		}
		if (bus && busn > 0 && top->dbg_z80_acc && !zacc_d) {
			fprintf(bus, "%ld %04X %c%c %02X\n", frame, top->dbg_z80_addr, top->dbg_z80_io ? 'I' : 'M',
			        top->dbg_z80_rw ? 'R' : 'W', top->dbg_z80_rw ? top->dbg_z80_rdata : top->dbg_z80_wdata);
			busn--;
		}
		zacc_d = top->dbg_z80_acc;
		// MS1_WLOG=<first>: from that frame on, the raster lines of the 68000's
		// palette and layer-1 scroll writes, to set against MAME's own taps.
		if (wlog_from >= 0 && frame >= wlog_from && top->tr_valid && top->tr_we) {
			unsigned a = top->tr_addr;
			if (a >= 0x088000 && a < 0x088800) { npal++; pal_lo = std::min(pal_lo, (int)top->vcount_o); pal_hi = std::max(pal_hi, (int)top->vcount_o); }
			if (a >= 0x084208 && a < 0x08420E) { nscr++; scr_lo = std::min(scr_lo, (int)top->vcount_o); scr_hi = std::max(scr_hi, (int)top->vcount_o); }
		}
		if (trl && trn > 0 && top->tr_valid) {
			fprintf(trl, "%ld %06X %c %04X\n", frame, top->tr_addr, top->tr_we ? 'W' : 'R', top->tr_data);
			trn--;
		}
		if (top->vblank_rise) {
			long nz = 0;
			for (size_t i = 0; i < (size_t)W * H; i++) if (fb[i*3] | fb[i*3+1] | fb[i*3+2]) nz++;
			if (frame % every == 0)
				printf("f=%ld pix=%zu nonblack=%ld acc=%u vregw=%u vramw=%u irq=%u/%u/%u ym=+%u latchw=%u latchr=+%u romwait=%u sprpass=%u late=%u scf=%04X t0=%04X,%04X,%04X t1=%04X,%04X,%04X\n",
				       frame, p, nz, top->dbg_acc, top->dbg_vregw, top->dbg_vramw,
				       top->dbg_irq1 - i1, top->dbg_irq2 - i2, top->dbg_irq3 - i3,
				       top->dbg_ym_writes - ym0, 0u, top->dbg_latch_reads - lr0,
				       top->dbg_romwait, top->dbg_spr_pass_cycles, top->dbg_spr_late_swaps,
				       top->dbg_scf, top->dbg_t0x, top->dbg_t0y, top->dbg_t0c, top->dbg_t1x, top->dbg_t1y, top->dbg_t1c);
			fflush(stdout);
			if (wlog_from >= 0 && frame >= wlog_from) {
				printf("  wlog f=%ld pal %d writes lines %d..%d | l1 scroll %d writes lines %d..%d\n",
				       frame, npal, pal_lo, pal_hi, nscr, scr_lo, scr_hi);
				npal = nscr = 0; pal_lo = scr_lo = 999; pal_hi = scr_hi = -1;
			}
			ym0 = top->dbg_ym_writes; lr0 = top->dbg_latch_reads;
			i1 = top->dbg_irq1; i2 = top->dbg_irq2; i3 = top->dbg_irq3;
			if (ppm.count(frame)) {
				char fn[64]; snprintf(fn, sizeof fn, "frame_%05ld.ppm", frame);
				FILE *f = fopen(fn, "wb"); fprintf(f, "P6\n%d %d\n255\n", W, H);
				fwrite(fb.data(), 1, fb.size(), f); fclose(f);
			}
			if (framedir && frame >= envl("MS1_FRAMEFROM", 0)) {
				char fn[512]; snprintf(fn, sizeof fn, "%s/f%05ld.raw", framedir, frame);
				FILE *f = fopen(fn, "wb"); fwrite(fb.data(), 1, fb.size(), f); fclose(f);
				if (getenv("MS1_IDX")) {
					snprintf(fn, sizeof fn, "%s/i%05ld.raw", framedir, frame);
					f = fopen(fn, "wb"); fwrite(ib.data(), 2, ib.size(), f); fclose(f);
				}
			}
			std::fill(fb.begin(), fb.end(), 0); p = 0;
			frame++;
			if (frame == ss_at) {
				unsigned ym_before = top->dbg_ym_writes;
				printf("savestate at frame %ld (ym writes so far %u)\n", frame, ym_before);
				park(); stream_out(); stream_in(); release();
			}
		}
		if (top->dbg_slatch_we) sl0++;
	}
	printf("done: %ld frames, %ld clk, latch writes %u, ym writes %u\n", frame, ticks_total, sl0, top->dbg_ym_writes);
	if (wav) fclose(wav); if (wfm) fclose(wfm); if (wssg) fclose(wssg); if (bus) fclose(bus); if (trl) fclose(trl);
	delete top; return 0;
}
