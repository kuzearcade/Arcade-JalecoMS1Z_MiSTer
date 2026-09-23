// Jaleco Mega System 1-Z core: the main-CPU board, the sound board and the
// video, with the raster that paces them.
//
// 384 x 278 at a 6 MHz pixel clock, visible 256 x 224 from row 16 -- the
// Mega System 1 video family's raster, which the whole shared video pipeline
// is built for. MAME's system_Z instead declares a 256-line screen at
// set_refresh_hz(56.18) ("same as nmk16.cpp based on YT videos"); the frame
// rates agree to 0.04 %, the interrupt spacing does not (docs/PLAN.md fact 5).
// HTOTAL and VTOTAL are parameters so a SIMULATION can run MAME's timing:
// 417 x 256 is exactly MAME's 56.18 Hz 256-line frame at a 6 MHz pixel
// clock -- and 417 x 256 = 384 x 278 = 106,752 pixel clocks, so the frame is
// the same length and only the interrupt spacing moves. That is what
// separates "the raster model differs" from "bug" (docs/known-issues.md
// MS1Z-5). The shipped core is 384 x 278.
//
// Derived from Arcade-JalecoMS1BCD_MiSTer's rtl/ms1bcd/ms1bcd_core.sv.

module ms1z_core #(
	parameter integer LOOKAHEAD = 0,
	parameter [8:0]   HTOTAL = 9'd384,
	parameter [8:0]   VTOTAL = 9'd278,
	// Raster line at whose END the Sprite Data snapshot is taken and the
	// sprite pass starts. MAME draws type-Z sprites from LIVE work RAM at each
	// (partial) screen update, so when the board samples it is a measurement
	// against the oracle, not an assumption; 239 = vblank_rise, MS1BCD's point.
	// The pass must finish before row 16 is displayed.
	parameter [8:0]   SPR_SNAP_LINE = 9'd239
) (
	input               clk,           // 48 MHz
	input               reset,

	output      [16:0]  rom_addr,
	input       [15:0]  rom_data,
	input               rom_ready,

	input        [7:0]  in_p1, in_p2, in_dsw1, in_dsw2, in_system,

	input               pause,
	input               osd_flip,
	input       [23:0]  hs_addr,
	input        [7:0]  hs_din,
	output       [7:0]  hs_dout,
	input               hs_write,
	input               hs_access,

	// tile ROMs: live (prefetch) and use addresses per layer
	output      [20:0]  l0_rom_addr, l1_rom_addr,
	output      [20:0]  l0_rom_use_addr, l1_rom_use_addr,
	input        [7:0]  l0_rom_data, l1_rom_data,
	input               l0_rom_ready, l1_rom_ready,
	output      [21:0]  spr_rom_addr,
	input        [7:0]  spr_rom_data,
	input               spr_rom_ready,

	// Z80 program window load
	input               zrom_we,
	input       [13:0]  zrom_waddr,
	input        [7:0]  zrom_wdata,

	output signed [15:0] snd,

	output      [23:0]  rgb,
	output              rgb_valid,
	output       [9:0]  dbg_pal_idx,
	output              vblank_rise,
	output       [8:0]  vcount_o,
	output       [8:0]  hcount_o,
	output              ce_pix_o,

	// probes
	output      [15:0]  dbg_scf, dbg_t0x, dbg_t0y, dbg_t0c, dbg_t1x, dbg_t1y, dbg_t1c,
	output      [31:0]  dbg_acc, dbg_vregw, dbg_vramw,
	output      [31:0]  dbg_irq1, dbg_irq2, dbg_irq3,
	output      [31:0]  dbg_romwait, dbg_romacc,
	output      [23:0]  tr_addr,
	output      [15:0]  tr_data,
	output              tr_we, tr_valid,
	output      [31:0]  dbg_ym_writes, dbg_latch_reads,
	output signed [15:0] dbg_fm_snd,
	output       [9:0]  dbg_psg_snd,
	output      [15:0]  dbg_z80_addr,
	output              dbg_z80_acc, dbg_z80_rw, dbg_z80_io,
	output       [7:0]  dbg_z80_wdata, dbg_z80_rdata,
	output              dbg_slatch_we,
	output       [7:0]  dbg_slatch_data,
	output      [31:0]  dbg_spr_pass_cycles,
	output      [15:0]  dbg_spr_late_swaps,
	output reg  [31:0]  dbg_l0_miss, dbg_l1_miss, dbg_pix,

	// savestate
	input               ss_freeze,
	input               ss_resume,
	input               ss_active,
	input       [19:0]  ss_addr,
	input               ss_wr,
	input       [15:0]  ss_wdata,
	output reg  [15:0]  ss_rdata,
	output              ss_frozen,
	output              ss_parked,
	input               ss_replay,
	output              ss_replay_done
);
	// The whole savestate window: park, stream, resume (MS1-33).
	wire ss_hold = ss_freeze | ss_active | ss_resume;

	// ---------------------------------------------------------- raster
	reg [2:0] pdiv;
	reg [8:0] hcount, vcount;
	reg       ce_pix;
	wire      ss_ras = ss_active & (ss_addr[19:4] == 16'h1D04);
	always @(posedge clk) begin
		ce_pix <= 1'b0;
		if (reset) begin pdiv <= 3'd0; hcount <= 9'd0; vcount <= 9'd0; end
		else if (ss_hold & ~(ss_wr & ss_ras)) begin
			pdiv <= pdiv; hcount <= hcount; vcount <= vcount;
		end
		else if (ss_active & ss_wr & ss_ras) begin
			case (ss_addr[3:0])
				4'd0: begin hcount <= ss_wdata[12:4]; pdiv <= ss_wdata[3:1];
				            ce_pix <= ss_wdata[0]; end
				4'd1: vcount <= ss_wdata[8:0];
				default: ;
			endcase
		end
		else if (pdiv == 3'd7) begin
			pdiv <= 3'd0;
			ce_pix <= 1'b1;
			if (hcount == HTOTAL - 9'd1) begin
				hcount <= 9'd0;
				vcount <= (vcount == VTOTAL - 9'd1) ? 9'd0 : vcount + 9'd1;
			end else hcount <= hcount + 9'd1;
		end else pdiv <= pdiv + 3'd1;
	end
	assign vcount_o = vcount;
	assign hcount_o = hcount;
	assign ce_pix_o = ce_pix;

	wire vtick = ce_pix & (hcount == HTOTAL - 9'd1);
	assign vblank_rise = vtick & (vcount == 9'd239);   // entering line 240
	wire visible = (hcount < 9'd256) && (vcount >= 9'd16) && (vcount < 9'd240);

	// ------------------------------------------------------ main CPU side
	wire [12:0] v0a, v1a;
	wire [15:0] v0d, v1d;
	wire  [9:0] pala;
	wire [15:0] pald;
	wire [11:0] spra;
	wire [15:0] sprd;
	wire [15:0] r_scf, r0x, r0y, r0c, r1x, r1y, r1c;
	wire        spr_buf_busy;
	wire        slatch_we;
	wire  [7:0] slatch_data;
	wire [15:0] ss_main_rdata, ss_snd_rdata, ss_spr_rdata;
	wire        ss_m68k_parked, ss_z80_parked;

	// One pulse at the end of SPR_SNAP_LINE: snapshot, then the pass (which
	// waits for the snapshot's buf_busy to drop).
	wire spr_snap = vtick & (vcount == SPR_SNAP_LINE);
	reg  spr_start;
	always @(posedge clk) spr_start <= spr_snap;

	ms1z_main u_main (
		.clk(clk), .reset(reset),
		.rom_addr(rom_addr), .rom_data(rom_data), .rom_ready(rom_ready),
		.in_p1(in_p1), .in_p2(in_p2), .in_dsw1(in_dsw1), .in_dsw2(in_dsw2), .in_system(in_system),
		.pause(pause),
		.hs_addr(hs_addr), .hs_din(hs_din), .hs_dout(hs_dout),
		.hs_write(hs_write), .hs_access(hs_access),
		.vcount(vcount), .vtick(vtick),
		.tr_addr(tr_addr), .tr_data(tr_data), .tr_we(tr_we), .tr_valid(tr_valid),
		.v0_rd_addr(v0a), .v1_rd_addr(v1a), .v0_rd_data(v0d), .v1_rd_data(v1d),
		.pal_rd_addr(pala), .pal_rd_data(pald),
		.spr_snap(spr_snap), .spr_buf_busy(spr_buf_busy),
		.spr_rd_addr(spra), .spr_rd_data(sprd),
		.reg_screen_flag(r_scf),
		.reg_t0_sx(r0x), .reg_t0_sy(r0y), .reg_t0_ctrl(r0c),
		.reg_t1_sx(r1x), .reg_t1_sy(r1y), .reg_t1_ctrl(r1c),
		.slatch_we(slatch_we), .slatch_data(slatch_data),
		.dbg_acc(dbg_acc), .dbg_vregw(dbg_vregw), .dbg_vramw(dbg_vramw),
		.dbg_irq1(dbg_irq1), .dbg_irq2(dbg_irq2), .dbg_irq3(dbg_irq3),
		.dbg_romwait(dbg_romwait), .dbg_romacc(dbg_romacc),
		.ss_active(ss_active), .ss_addr(ss_addr), .ss_wr(ss_wr),
		.ss_wdata(ss_wdata), .ss_rdata(ss_main_rdata),
		.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_hold(ss_hold),
		.ss_m68k_parked(ss_m68k_parked)
	);
	assign dbg_scf = r_scf;
	assign dbg_t0x = r0x; assign dbg_t0y = r0y; assign dbg_t0c = r0c;
	assign dbg_t1x = r1x; assign dbg_t1y = r1y; assign dbg_t1c = r1c;
	assign dbg_slatch_we = slatch_we;
	assign dbg_slatch_data = slatch_data;

	// ------------------------------------------------------- sound board
	ms1z_sound u_sound (
		.clk(clk), .reset(reset), .sreset(r_scf[4]), .pause(pause),
		.latch_we(slatch_we), .latch_data(slatch_data),
		.zrom_we(zrom_we), .zrom_waddr(zrom_waddr), .zrom_wdata(zrom_wdata),
		.snd(snd),
		.ss_active(ss_active), .ss_addr(ss_addr), .ss_wr(ss_wr),
		.ss_wdata(ss_wdata), .ss_rdata(ss_snd_rdata),
		.ss_freeze(ss_freeze), .ss_resume(ss_resume), .ss_parked(ss_z80_parked),
		.ss_replay(ss_replay), .ss_replay_done(ss_replay_done),
		.dbg_ym_writes(dbg_ym_writes), .dbg_latch_reads(dbg_latch_reads),
		.dbg_fm_snd(dbg_fm_snd), .dbg_psg_snd(dbg_psg_snd),
		.dbg_addr(dbg_z80_addr), .dbg_acc(dbg_z80_acc), .dbg_rw(dbg_z80_rw), .dbg_io(dbg_z80_io),
		.dbg_wdata(dbg_z80_wdata), .dbg_rdata(dbg_z80_rdata),
		.dbg_irq_n(), .dbg_ym_div()
	);

	// Every CPU parked, and the readback merged. The Z80 held in reset by
	// screen_flag[4] reports parked (ss_z80_park's reset_n input).
	assign ss_frozen = ss_m68k_parked & ss_z80_parked;
	assign ss_parked = ss_m68k_parked | ss_z80_parked;

	reg [15:0] ss_ras_rdata;
	always @* begin
		case (ss_addr[3:0])
			4'd0: ss_ras_rdata = {3'd0, hcount[8:0], pdiv, ce_pix};
			4'd1: ss_ras_rdata = {7'd0, vcount};
			default: ss_ras_rdata = 16'h0000;
		endcase
	end
	wire ss_plane_sel = (ss_addr[19:16] == 4'h2) | (ss_addr[19:5] == 15'h0E83);  // plane + sprite FSM
	wire ss_from_snd  = (ss_addr[19:11] == 9'h03E)      // Z80 RAM
	                  | (ss_addr[19:7]  == 13'h03C0)    // YM shadow
	                  | (ss_addr[19:4]  == 16'h1D02)    // sound scalars
	                  | (ss_addr[19:4]  == 16'h1D03);   // Z80 park
	reg ss_from_snd_d, ss_plane_d, ss_ras_d;
	reg [15:0] ss_ras_d_data;
	always @(posedge clk) begin
		ss_from_snd_d <= ss_from_snd;
		ss_plane_d    <= ss_plane_sel;
		ss_ras_d      <= ss_ras;
		ss_ras_d_data <= ss_ras_rdata;
	end
	always @(posedge clk)
		ss_rdata <= ss_ras_d      ? ss_ras_d_data
		          : ss_plane_d    ? ss_spr_rdata
		          : ss_from_snd_d ? ss_snd_rdata
		                          : ss_main_rdata;

	// ------------------------------------------------------------ video
	always @(posedge clk) begin
		if (reset) begin dbg_l0_miss <= 0; dbg_l1_miss <= 0; dbg_pix <= 0; end
		else if (ce_pix & visible) begin
			dbg_pix <= dbg_pix + 32'd1;
			if (!l0_rom_ready) dbg_l0_miss <= dbg_l0_miss + 32'd1;
			if (!l1_rom_ready) dbg_l1_miss <= dbg_l1_miss + 32'd1;
		end
	end

	wire [12:0] v2a_unused;
	wire [20:0] l2a_unused, l2u_unused;
	wire [11:0] obja_unused;
	ms1_video #(.LOOKAHEAD(LOOKAHEAD), .TOTAL_W(HTOTAL), .BOARD_Z(1),
	            .L0_ROM_MASK(21'h01FFFF),     // scroll1: 128 KB, 4096 8x8 tiles
	            .L1_ROM_MASK(21'h00FFFF),     // scroll2:  64 KB, 2048 tiles
	            .SPR_TILE_MASK(13'h03FF))     // sprites: 128 KB, 1024 16x16 tiles
	u_video (
		.clk(clk), .ce(ce_pix), .reset(reset),
		.mode(2'd0), .nlayers(2'd2), .osd_flip(osd_flip),
		.spr_buf_busy(spr_buf_busy),
		// no active_layers register on type Z: MAME forces 0x000b (layers 0
		// and 1 and sprites); no sprite_flag, no sprite bank.
		.active_layers(16'h000B), .sprite_flag(16'h0000),
		.sprite_bank(16'h0000), .screen_flag(r_scf),
		.t0_sx(r0x), .t0_sy(r0y), .t0_ctrl(r0c),
		.t1_sx(r1x), .t1_sy(r1y), .t1_ctrl(r1c),
		.t2_sx(16'd0), .t2_sy(16'd0), .t2_ctrl(16'd0),
		.vx(hcount), .vy(vcount - 9'd16), .vvalid(visible),
		.l0_vram_addr(v0a), .l1_vram_addr(v1a), .l2_vram_addr(v2a_unused),
		.l0_vram_data(v0d), .l1_vram_data(v1d), .l2_vram_data(16'd0),
		.l0_rom_addr(l0_rom_addr), .l1_rom_addr(l1_rom_addr), .l2_rom_addr(l2a_unused),
		.l0_rom_use_addr(l0_rom_use_addr), .l1_rom_use_addr(l1_rom_use_addr),
		.l2_rom_use_addr(l2u_unused),
		.l0_rom_data(l0_rom_data), .l1_rom_data(l1_rom_data), .l2_rom_data(8'hFF),
		.spr_start(spr_start), .spr_busy(),
		.obj_addr(obja_unused), .spr_ram_addr(spra),
		.obj_data(16'd0), .spr_ram_data(sprd),
		.spr_rom_addr(spr_rom_addr), .spr_rom_data(spr_rom_data),
		.spr_rom_ready(spr_rom_ready),
		.ss_rst_dbg(1'b0),
		.dbg_o0(), .dbg_o2(),
		.ss_active(ss_active), .ss_addr(ss_addr), .ss_wr(ss_wr),
		.ss_wdata(ss_wdata), .ss_spr_rdata(ss_spr_rdata),
		.dbg_spr_pass_cycles(dbg_spr_pass_cycles), .dbg_spr_late_swaps(dbg_spr_late_swaps),
		.prom_addr(), .prom_data(8'd0),
		.pal_addr(pala), .pal_data(pald),
		.rgb(rgb), .rgb_valid(rgb_valid), .dbg_pal_idx(dbg_pal_idx)
	);
endmodule
