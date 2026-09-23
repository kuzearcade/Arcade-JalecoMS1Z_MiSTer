// Jaleco Mega System 1-Z sound board: a Z80 at 3 MHz and one YM2203 at
// 1.5 MHz, fed by a one-way 8-bit latch from the main 68000.
//
// MAME (megasys1.cpp:798-810, 2259, 2285):
//   Z80 mem  0000-3FFF ROM (16 KB of lom_01.rom; the file is 64 KB and every
//                      byte above 0x3E30 is 0xFF -- docs/known-issues.md MS1Z-1)
//            C000-C7FF RAM, 2 KB, no mirror
//            E000      R  sound latch (low byte)
//            F000      W  nopw -- decoded and discarded
//   Z80 io   00-01     YM2203 (global_mask 0xff)
//   YM2203 IRQ -> Z80 INT, level-sensitive; FM + 3 SSG routed to mono at 0.5.
//
// The latch raises nothing. soundlatch_z_w asserts Z80 input line 5, which a
// Z80 does not have (z80.h: IRQ0, WAIT, BUSREQ), and execute_set_input
// ignores it. The ROM agrees: IM 1, the YM timer handler at 0x0038 polls
// 0xE000 through the routine at 0x0113, and 0x0066 is the MIDDLE of that
// handler, so the board cannot be wiring the latch to NMI (MS1Z-1).
//
// screen_flag bit 4 holds the Z80 -- ONLY the Z80 -- in reset. MS1BCD's
// equivalent resets the YM2151 and both OKIs too (MS1-30); here the YM2203
// has no reset from it in MAME (screen_flag_w's ym2151 cast fails for it).
//
// Built from Arcade-SandScrp_MiSTer's Z80/jt03 block and NMK16's
// tdragon2_core.sv (docs/provenance.md), with MS1BCD's two savestate audio
// bugs designed out (MS1-61, MS1-62):
//   * the register shadow is captured from the LIVE Z80 bus at the write edge;
//   * the YM clock enable is free-running -- nothing freezes it in a save;
//   * the replay FSM lets go of the chip the moment ss_replay drops, finished
//     or not.
module ms1z_sound (
	input               clk,           // 48 MHz
	input               reset,         // board reset: Z80, YM2203, latch
	input               sreset,        // screen_flag[4]: Z80 only
	input               pause,         // OSD pause gates the Z80, not the chip

	input               latch_we,
	input        [7:0]  latch_data,

	// the Z80 program window, written during the ROM download (BRAM; no ROM
	// data is ever compiled in -- it arrives from the .mra)
	input               zrom_we,
	input       [13:0]  zrom_waddr,
	input        [7:0]  zrom_wdata,

	output signed [15:0] snd,

	// savestate
	input               ss_active,
	input       [19:0]  ss_addr,
	input               ss_wr,
	input       [15:0]  ss_wdata,
	output reg  [15:0]  ss_rdata,
	input               ss_freeze,
	input               ss_resume,
	output              ss_parked,
	input               ss_replay,
	output              ss_replay_done,

	// probes
	output reg  [31:0]  dbg_ym_writes,
	output reg  [31:0]  dbg_latch_reads,
	output signed [15:0] dbg_fm_snd,
	output       [9:0]  dbg_psg_snd,
	output      [15:0]  dbg_addr,
	output              dbg_acc, dbg_rw, dbg_io,
	output       [7:0]  dbg_wdata, dbg_rdata,
	output              dbg_irq_n,
	output       [1:0]  dbg_ym_div
);
	// ------------------------------------------------------------ clocks
	reg [3:0] zdiv = 4'd0;
	reg [4:0] ydiv = 5'd0;
	always @(posedge clk) begin
		zdiv <= zdiv + 4'd1;          // 48 / 16 = 3 MHz
		ydiv <= ydiv + 5'd1;          // 48 / 32 = 1.5 MHz
	end
	wire z80_cen = (zdiv == 4'd15);
	wire ym_cen  = (ydiv == 5'd31);

	// ------------------------------------------------------------- Z80
	wire [15:0] z80_a;
	wire  [7:0] z80_do;
	wire  [7:0] z80_di;
	wire        z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
	wire        z80_rfsh_n, z80_halt_n, z80_busak_n;
	wire        ym_irq_n;
	wire        z80_nmi_park, z80_sel_mon;
	wire  [7:0] z80_mon_data;
	wire        z80_reset_n = ~(reset | sreset);

	T80s z80_cpu (
		.RESET_n(z80_reset_n), .CLK(clk), .CEN(z80_cen & ~pause), .WAIT_n(1'b1),
		.INT_n(ym_irq_n), .NMI_n(~z80_nmi_park), .BUSRQ_n(1'b1), .OUT0(1'b0),
		.DI(z80_di), .M1_n(z80_m1_n), .MREQ_n(z80_mreq_n), .IORQ_n(z80_iorq_n),
		.RD_n(z80_rd_n), .WR_n(z80_wr_n), .RFSH_n(z80_rfsh_n), .HALT_n(z80_halt_n),
		.BUSAK_n(z80_busak_n), .A(z80_a), .DO(z80_do)
	);

	wire z80_mem_re = ~z80_mreq_n & ~z80_rd_n;
	wire z80_mem_we = ~z80_mreq_n & ~z80_wr_n;
	wire z80_io_re  = ~z80_iorq_n & ~z80_rd_n;
	wire z80_io_we  = ~z80_iorq_n & ~z80_wr_n;

	// Every select is qualified with the matching strobe. An IN A,(n) drives
	// register A onto A15..A8, so an unqualified memory decode answers I/O
	// reads with ROM bytes -- NMK16's silent-music bug, NMK-14.
	wire sel_rom   = z80_mem_re & (z80_a < 16'h4000);
	wire sel_ram   = (z80_a >= 16'hC000) & (z80_a < 16'hC800);
	wire sel_latch = z80_mem_re & (z80_a == 16'hE000);
	wire sel_ym_r  = z80_io_re & (z80_a[7:1] == 7'd0);
	wire sel_ym_w  = z80_io_we & (z80_a[7:1] == 7'd0);

	// ---- program window: 16 KB BRAM, filled by the download
	reg [7:0] zrom [0:16383];
	reg [7:0] zrom_q;
	always @(posedge clk) begin
		if (zrom_we) zrom[zrom_waddr] <= zrom_wdata;
		zrom_q <= zrom[z80_a[13:0]];
	end

	// ---- work RAM: 2 KB, one byte per savestate word
	wire ss_w      = ss_active & ss_wr;
	wire ss_zram   = ss_active & (ss_addr[19:11] == 9'h03E);   // 0x1F000 2048
	wire ss_ymsh   = ss_active & (ss_addr[19:7]  == 13'h03C0); // 0x1E000  128
	wire ss_smisc  = ss_active & (ss_addr[19:4]  == 16'h1D02); // 0x1D020   16
	wire ss_zpark  = ss_active & (ss_addr[19:4]  == 16'h1D03); // 0x1D030    2
	reg  [7:0] zram [0:2047];
	reg  [7:0] zram_q;
	wire [10:0] zr_a = ss_active ? ss_addr[10:0] : z80_a[10:0];
	always @(posedge clk) begin
		if (ss_w & ss_zram)                zram[zr_a] <= ss_wdata[7:0];
		else if (sel_ram & z80_mem_we)     zram[zr_a] <= z80_do;
		zram_q <= zram[zr_a];
	end

	// ---- the latch (generic_latch_16, low byte). No reset line from the
	// Z80's reset: MAME's latch survives a sound-CPU reset.
	reg [7:0] latch;
	always @(posedge clk) begin
		if (reset) latch <= 8'h00;
		else if (ss_w & ss_smisc & (ss_addr[3:0] == 4'd0)) latch <= ss_wdata[7:0];
		else if (latch_we) latch <= latch_data;
	end
	reg sel_latch_d;
	always @(posedge clk) begin
		sel_latch_d <= sel_latch;
		if (reset) dbg_latch_reads <= 32'd0;
		else if (sel_latch & ~sel_latch_d) dbg_latch_reads <= dbg_latch_reads + 32'd1;
	end

	// ------------------------------------------------------------ YM2203
	// Writes are stretched to 40 clocks with the YM's OWN copy of a0 and the
	// data, captured at the write edge. (MS1BCD fed its chip from a latch
	// shared with every other bus write -- MS1-62's still-open window.)
	// Reads use the live port decode unless a stretch is in flight: jt03 has
	// no read strobe and its `addr` input also selects what a read returns
	// (NMK16, docs/tier2-system.md "a write-only addr latch").
	wire       rep_on = ss_replay;
	reg        rep_ym_we = 1'b0, rep_a0 = 1'b0;
	reg  [7:0] rep_data = 8'h00;
	wire       ym_we_raw = rep_on ? rep_ym_we : sel_ym_w;
	wire       ym_a0_src = rep_on ? rep_a0    : z80_a[0];
	wire [7:0] ym_d_src  = rep_on ? rep_data  : z80_do;
	reg        ym_we_prev = 1'b0;
	reg  [7:0] ym_din_latch = 8'h00;
	reg        ym_addr_latch = 1'b0;
	reg  [5:0] ym_wr_hold = 6'd0;
	wire       ym_wr_edge = ym_we_raw & ~ym_we_prev;
	always @(posedge clk) begin
		ym_we_prev <= ym_we_raw;
		if (ym_wr_edge) begin
			ym_din_latch  <= ym_d_src;
			ym_addr_latch <= ym_a0_src;
			ym_wr_hold    <= 6'd40;
		end else if (ym_wr_hold != 6'd0) ym_wr_hold <= ym_wr_hold - 6'd1;
		if (reset) dbg_ym_writes <= 32'd0;
		else if (ym_wr_edge & ~rep_on) dbg_ym_writes <= dbg_ym_writes + 32'd1;
	end
	wire ym_wr_n     = ~(ym_wr_hold != 6'd0);
	wire ym_addr_sel = (ym_wr_hold != 6'd0) ? ym_addr_latch : z80_a[0];

	wire  [7:0] ym_dout;
	wire signed [15:0] ym_snd;
	wire signed [15:0] fm_snd_w;
	wire        [9:0]  psg_snd_w;
	jt03 u_ym (
		.rst(reset), .clk(clk), .cen(ym_cen),
		.din(ym_din_latch), .addr(ym_addr_sel), .cs_n(1'b0), .wr_n(ym_wr_n),
		.dout(ym_dout), .irq_n(ym_irq_n),
		// lomakai never reads the I/O ports: its two `in a,(1)` are a
		// read-modify-write of SSG register 7 (0x084A, 0x08C6). MS1Z-1.
		.IOA_in(8'hFF), .IOB_in(8'hFF), .IOA_out(), .IOB_out(), .IOA_oe(), .IOB_oe(),
		.psg_A(), .psg_B(), .psg_C(), .fm_snd(fm_snd_w), .psg_snd(psg_snd_w),
		.snd(ym_snd), .snd_sample(), .debug_view()
	);
	// Sand Scorpion measured this exact mix (jt12_top's fm + {psg,5'd0},
	// then halved) against MAME's routed 0.5: FM lands at MAME's level, and
	// halving it again made every band worse (SS-10, 3f4ac90). Change it only
	// on a measurement against the isolated halves.
	assign snd = ym_snd >>> 1;
	assign dbg_fm_snd  = fm_snd_w;
	assign dbg_psg_snd = psg_snd_w;
	assign dbg_irq_n   = ym_irq_n;

	// ------------------------------------------------ register shadow
	// Two registers per word, as Sand Scorpion does. The select register and
	// the PRESCALER are tracked beside it: lomakai selects the /2 prescaler
	// with a bare address write of 0x2F at reset (Z80 0x001B), and jt03
	// implements that (jt12_mmr.v:279-281) -- an address write with no data
	// that a register shadow alone cannot see.
	reg  [7:0] ym_sh_e [0:127];
	reg  [7:0] ym_sh_o [0:127];
	reg  [7:0] ym_sh_addr = 8'h00;
	reg  [1:0] ym_div = 2'b10;        // jt03's reset value: FM 1/6, SSG 1/4
	reg [15:0] ym_sh_q;
	reg  [7:0] rep_addr = 8'd0;
	wire [6:0] sh_raddr = ss_active ? ss_addr[6:0] : rep_addr[6:0];
	always @(posedge clk) begin
		if (ss_w & ss_ymsh) begin
			ym_sh_e[ss_addr[6:0]] <= ss_wdata[7:0];
			ym_sh_o[ss_addr[6:0]] <= ss_wdata[15:8];
		end else if (~rep_on & ym_wr_edge) begin
			// ym_a0_src / ym_d_src are the write that IS the edge (MS1-62)
			if (ym_a0_src) begin
				if (ym_sh_addr[0]) ym_sh_o[ym_sh_addr[7:1]] <= ym_d_src;
				else               ym_sh_e[ym_sh_addr[7:1]] <= ym_d_src;
			end
		end
		ym_sh_q <= {ym_sh_o[sh_raddr], ym_sh_e[sh_raddr]};
	end
	always @(posedge clk) begin
		if (reset) begin ym_sh_addr <= 8'h00; ym_div <= 2'b10; end
		else if (ss_w & ss_smisc & (ss_addr[3:0] == 4'd1)) begin
			ym_sh_addr <= ss_wdata[7:0]; ym_div <= ss_wdata[9:8];
		end else if (~rep_on & ym_wr_edge & ~ym_a0_src) begin
			ym_sh_addr <= ym_d_src;
			case (ym_d_src)
				8'h2D: ym_div[1] <= 1'b1;
				8'h2E: ym_div[0] <= 1'b1;
				8'h2F: ym_div    <= 2'b00;
				default: ;
			endcase
		end
	end
	assign dbg_ym_div = ym_div;

	// ------------------------------------------------ replay after a load
	// Order:
	//   1. the prescaler, as bare address writes: 0x2F, then 0x2D / 0x2E if
	//      the saved setting has them;
	//   2. every register 0x00-0xFF from the shadow as select + data, except
	//      0x28 (key on) and 0x2C-0x2F -- re-keying would restart whatever
	//      note was sounding;
	//   3. a key-off sweep of 0x28 for channels 0-2;
	//   4. the select register the driver last chose, as a bare address
	//      write, so the next data write lands where the driver expects.
	// Each chip write is one stretched write with 256 clocks after it -- far
	// more than jt03's 32-cycle busy. The FSM returns to idle and lets go of
	// the chip AS SOON AS ss_replay drops, whether it finished or not: a
	// replay that could outlive the load is how MS1-61 silenced MS1BCD.
	localparam [3:0] R_IDLE = 4'd0, R_PRE = 4'd1, R_FETCH = 4'd2, R_FETCH2 = 4'd3,
	                 R_ADDR = 4'd4, R_DATA = 4'd5, R_NEXT = 4'd6, R_SWEEP = 4'd7,
	                 R_SEL = 4'd8, R_DONE = 4'd9, R_WAIT = 4'd10;
	reg  [3:0] rep_st = R_IDLE, rep_ret = R_IDLE;
	reg  [1:0] pre_i;
	reg        rep_odd;
	reg [15:0] rep_word;
	reg  [8:0] rep_wait;
	reg        rep_done_r = 1'b0;
	wire [7:0] rep_reg  = {rep_addr[6:0], rep_odd};
	wire [7:0] rep_val  = rep_odd ? rep_word[15:8] : rep_word[7:0];
	wire       rep_skip = (rep_reg == 8'h28) | (rep_reg[7:2] == 6'b001011);
	assign ss_replay_done = rep_done_r;

	task automatic ym_write(input a0, input [7:0] d, input [3:0] next);
		begin
			rep_a0 <= a0; rep_data <= d; rep_ym_we <= 1'b1;
			rep_wait <= 9'd0; rep_ret <= next; rep_st <= R_WAIT;
		end
	endtask

	always @(posedge clk) begin
		rep_ym_we <= 1'b0;
		if (reset | ~ss_replay) begin
			rep_st <= R_IDLE; rep_done_r <= 1'b0;
		end else case (rep_st)
			R_IDLE: begin
				rep_addr <= 8'd0; rep_odd <= 1'b0; pre_i <= 2'd0;
				rep_st <= R_PRE;
			end
			R_PRE: begin
				case (pre_i)
					2'd0: begin pre_i <= 2'd1; ym_write(1'b0, 8'h2F, R_PRE); end
					2'd1: begin pre_i <= 2'd2;
					            if (ym_div[1]) ym_write(1'b0, 8'h2D, R_PRE); end
					2'd2: begin pre_i <= 2'd3;
					            if (ym_div[0]) ym_write(1'b0, 8'h2E, R_PRE); end
					default: rep_st <= R_FETCH;
				endcase
			end
			R_FETCH:  rep_st <= R_FETCH2;
			R_FETCH2: begin rep_word <= ym_sh_q; rep_st <= R_ADDR; end
			R_ADDR:   if (rep_skip) rep_st <= R_NEXT;
			          else ym_write(1'b0, rep_reg, R_DATA);
			R_DATA:   ym_write(1'b1, rep_val, R_NEXT);
			R_NEXT: begin
				if (~rep_odd) begin rep_odd <= 1'b1; rep_st <= R_ADDR; end
				else if (rep_addr[6:0] == 7'd127) begin
					rep_odd <= 1'b0; rep_addr <= 8'd0; rep_st <= R_SWEEP;
				end else begin
					rep_odd <= 1'b0; rep_addr <= rep_addr + 8'd1; rep_st <= R_FETCH;
				end
			end
			// key off channels 0, 1, 2: select 0x28, then data = channel
			R_SWEEP: begin
				if (rep_addr == 8'd3) rep_st <= R_SEL;
				else if (~rep_odd) begin rep_odd <= 1'b1; ym_write(1'b0, 8'h28, R_SWEEP); end
				else begin
					rep_odd <= 1'b0; rep_addr <= rep_addr + 8'd1;
					ym_write(1'b1, rep_addr, R_SWEEP);
				end
			end
			R_SEL:  ym_write(1'b0, ym_sh_addr, R_DONE);
			R_DONE: rep_done_r <= 1'b1;
			R_WAIT: begin
				rep_wait <= rep_wait + 9'd1;
				if (rep_wait == 9'd296) rep_st <= rep_ret;   // 40 stretch + 256
			end
			default: rep_st <= R_IDLE;
		endcase
	end

	// ------------------------------------------------ Z80 savestate park
	wire [15:0] ss_zpark_rdata;
	ss_z80_park u_zpark (
		.clk(clk), .cen(z80_cen), .reset_n(z80_reset_n),
		.park_req(ss_freeze), .parked(ss_parked), .resume(ss_resume),
		.a(z80_a), .m1_n(z80_m1_n), .mreq_n(z80_mreq_n), .iorq_n(z80_iorq_n),
		.rd_n(z80_rd_n), .wr_n(z80_wr_n), .wait_n(1'b1),
		.dout(z80_do), .din_bus(z80_rdata),
		.nmi_park(z80_nmi_park), .sel_mon(z80_sel_mon), .mon_data(z80_mon_data),
		.ss_sel(ss_addr[0]), .ss_wr(ss_w & ss_zpark), .ss_wdata(ss_wdata),
		.ss_rdata(ss_zpark_rdata)
	);

	// ------------------------------------------------ Z80 read mux
	// Unmapped reads return 0x00, MAME's default unmap value for both spaces.
	reg [7:0] z80_rdata;
	always @* begin
		if      (sel_rom)                z80_rdata = zrom_q;
		else if (sel_ram & z80_mem_re)   z80_rdata = zram_q;
		else if (sel_latch)              z80_rdata = latch;
		else if (sel_ym_r)               z80_rdata = ym_dout;
		else                             z80_rdata = 8'h00;
	end
	assign z80_di = z80_sel_mon ? z80_mon_data : z80_rdata;

	// ------------------------------------------------ savestate readback
	reg [15:0] ss_smisc_rdata;
	always @* begin
		case (ss_addr[3:0])
			4'd0: ss_smisc_rdata = {8'd0, latch};
			4'd1: ss_smisc_rdata = {6'd0, ym_div, ym_sh_addr};
			default: ss_smisc_rdata = 16'h0000;
		endcase
	end
	always @(posedge clk) begin
		if      (ss_zram)  ss_rdata <= {8'd0, zram_q};
		else if (ss_ymsh)  ss_rdata <= ym_sh_q;
		else if (ss_zpark) ss_rdata <= ss_zpark_rdata;
		else if (ss_smisc) ss_rdata <= ss_smisc_rdata;
		else               ss_rdata <= 16'h0000;
	end

	// ------------------------------------------------ probes
	assign dbg_addr  = z80_a;
	assign dbg_acc   = (z80_mem_re | z80_mem_we | z80_io_re | z80_io_we) & z80_m1_n;
	assign dbg_rw    = ~z80_rd_n;
	assign dbg_io    = ~z80_iorq_n;
	assign dbg_wdata = z80_do;
	assign dbg_rdata = z80_di;
endmodule
