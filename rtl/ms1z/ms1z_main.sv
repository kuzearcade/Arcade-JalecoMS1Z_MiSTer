// Jaleco Mega System 1-Z main-CPU subsystem: the 68000, the board decode, the
// scanline interrupt timer, and the one-way sound latch.
//
// Derived from Arcade-JalecoMS1BCD_MiSTer's rtl/ms1bcd/ms1_main.sv (see
// docs/provenance.md). Everything that board needed for protection, System D
// and the object-RAM double buffer is gone; what is left is MAME's
// megasys1Z_map, which is megasys_base_map plus one latch write
// (megasys1.cpp:251-281):
//
//   global_mask(0xfffff) -- 20-bit decode, applied BEFORE the compare (MS1-21)
//   000000-03FFFF  program ROM, 256 KB
//   080000         SYSTEM   (r, 16 bits; high byte declared unknown -> 1s)
//   080002         P1       (r; high byte undeclared -> 0s)
//   080004         P2       (r; high byte declared unknown -> 1s)
//   080006         DSW      (r; DSW1 low byte, DSW2 high byte)
//   084200-084205  layer 0 scroll X / Y / control   (READABLE: scroll_r)
//   084208-08420D  layer 1 scroll X / Y / control   (readable)
//   084300         screen_flag (w): bit 0 flip, bit 4 holds the Z80 in reset
//   084308         sound latch (w), low byte only, no reply path
//   088000-0887FF  palette, RRRRGGGGBBBBRGBx
//   08C000-08DFFF  "Object RAM", mirrored at 08E000. Mapped as RAM and never
//                  drawn from on type Z -- and never referenced by lomakai's
//                  program either (docs/known-issues.md MS1Z-3). Kept because
//                  MAME maps it.
//   090000-093FFF  layer 0 VRAM      094000-097FFF  layer 1 VRAM
//   0F0000-0FFFFF  work RAM; Sprite Data is work RAM + 0x8000 bytes
//
// WORK RAM BYTE WRITES MIRROR INTO BOTH HALVES (MAME ram_w, "DON'T use
// COMBINE_DATA"). Every OTHER RAM on this bus is COMBINE_DATA in MAME, so a
// byte write changes only its own lane; those are written with byte enables
// here. (MS1BCD writes the whole word to palette/VRAM/object RAM.)
//
// Interrupts (megasys_base_scanline, megasys1.cpp:207-231), all HOLD_LINE:
// raster line 16 -> level 3, line 96 -> level 1, line 240 -> level 2.
// lomakai points levels 1 and 3 at the same handler (0x42C), which reloads
// layer 1's scroll from RAM: the line-96 interrupt is a mid-screen scroll
// split, and MAME renders it (ms1_tmap.cpp scroll_w calls update_partial).

module ms1z_main (
	input               clk,
	input               reset,

	// program ROM, served by the caller (256 KB, word addressed)
	output      [16:0]  rom_addr,
	input       [15:0]  rom_data,
	input               rom_ready,

	input        [7:0]  in_p1, in_p2, in_dsw1, in_dsw2, in_system,

	// OSD Pause: gates the phi enables, re-timed onto enPhi2 (MS1-39)
	input               pause,

	// high-score / cheat back door into work RAM, the 68000's own byte address
	input       [23:0]  hs_addr,
	input        [7:0]  hs_din,
	output       [7:0]  hs_dout,
	input               hs_write,
	input               hs_access,

	input        [8:0]  vcount,
	input               vtick,         // one pulse per scanline, at its end

	output reg  [23:0]  tr_addr,
	output reg  [15:0]  tr_data,
	output reg          tr_we,
	output reg          tr_valid,

	// video read ports
	input       [12:0]  v0_rd_addr, v1_rd_addr,
	output reg  [15:0]  v0_rd_data, v1_rd_data,
	input        [9:0]  pal_rd_addr,
	output reg  [15:0]  pal_rd_data,

	// LIVE Sprite Data (work RAM 0x0F8000-0x0F87FF, 1024 words) for the line
	// renderer, registered read. MAME's type-Z draw_sprites reads live work
	// RAM, and lomakai rewrites the list mid-frame (MS1Z-12), so there is no
	// snapshot and no buffer.
	input        [9:0]  spr_ra,
	output reg  [15:0]  spr_rq,

	output      [15:0]  reg_screen_flag,
	output      [15:0]  reg_t0_sx, reg_t0_sy, reg_t0_ctrl,
	output      [15:0]  reg_t1_sx, reg_t1_sy, reg_t1_ctrl,

	// sound latch: one pulse per write, the low byte
	output reg          slatch_we,
	output reg   [7:0]  slatch_data,

	output reg  [31:0]  dbg_acc, dbg_vregw, dbg_vramw,
	output reg  [31:0]  dbg_irq1, dbg_irq2, dbg_irq3,
	output reg  [31:0]  dbg_romwait, dbg_romacc,

	// savestate bus
	input               ss_active,
	input       [19:0]  ss_addr,
	input               ss_wr,
	input       [15:0]  ss_wdata,
	output reg  [15:0]  ss_rdata,
	input               ss_freeze,
	input               ss_resume,
	input               ss_hold,
	output              ss_m68k_parked
);
	// ------------------------------------------------------- 68000 clocking
	reg pause_68k = 1'b0;
	always @(posedge clk) if (enPhi2) pause_68k <= pause;

	// 6 MHz: an enable every 4 clocks, enPhi1/enPhi2 strictly alternating.
	reg [2:0] phdiv;
	localparam [2:0] PHDIV_MAX = 3'd3;
	reg enPhi1, enPhi2, phase;
	always @(posedge clk) begin
		if (reset) begin phdiv <= 3'd0; phase <= 1'b0; enPhi1 <= 1'b0; enPhi2 <= 1'b0; end
		else if (ss_w & ss_misc & (ss_addr[3:0] == 4'd4)) phdiv <= ss_wdata[2:0];
		else if (ss_w & ss_misc & (ss_addr[3:0] == 4'd5)) phase <= ss_wdata[1];
		else if (ss_active) begin enPhi1 <= 1'b0; enPhi2 <= 1'b0; end
		else begin
			enPhi1 <= 1'b0; enPhi2 <= 1'b0;
			if (phdiv == PHDIV_MAX) begin
				phdiv <= 3'd0;
				phase <= ~phase;
				if (phase) enPhi2 <= 1'b1; else enPhi1 <= 1'b1;
			end else phdiv <= phdiv + 3'd1;
		end
	end

	wire        eRWn, ASn, LDSn, UDSn, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] oEdb;
	wire [23:1] eab;
	reg  [15:0] iEdb;

	wire [23:0] byte_addr = {eab, 1'b0};
	wire        as_active = ~ASn & (~LDSn | ~UDSn);

	// ------------------------------------------------------------- decode
	wire [23:0] a = byte_addr & 24'h0FFFFF;

	wire sel_rom  = (a <  24'h040000);
	wire sel_in   = (a >= 24'h080000) & (a < 24'h080008);
	wire sel_vreg = (a >= 24'h084000) & (a < 24'h084400);
	wire sel_pal  = (a >= 24'h088000) & (a < 24'h088800);
	wire sel_obj  = (a >= 24'h08C000) & (a < 24'h090000);   // 8 KB + mirror
	wire sel_v0   = (a >= 24'h090000) & (a < 24'h094000);
	wire sel_v1   = (a >= 24'h094000) & (a < 24'h098000);
	wire sel_ram  = (a >= 24'h0F0000);                      // to 0FFFFF

	// The ROM address is HELD while the bus is not selecting ROM: rom_cache_n
	// refetches on any change, and a speculative fill landing between DTACK
	// and the data latch corrupts the word being read (MS1-50, SS-12).
	wire [16:0] rom_addr_live = a[17:1];
	reg  [16:0] rom_addr_held;
	always @(posedge clk) if (sel_rom) rom_addr_held <= rom_addr_live;
	assign rom_addr = sel_rom ? rom_addr_live : rom_addr_held;

	wire rom_stall = as_active & sel_rom & ~rom_ready;

	// Registered array reads are valid one clock after the address settles;
	// DTACK is held for that clock. A bus cycle is ~32 clk_sys at 6 MHz.
	reg  as_d1;
	always @(posedge clk) as_d1 <= as_active;
	wire arr_wait = as_active & eRWn & (sel_ram | sel_pal | sel_obj | sel_v0 | sel_v1) & ~as_d1;

	reg as_d_r;
	always @(posedge clk) as_d_r <= as_active;
	always @(posedge clk) begin
		if (reset) begin dbg_romwait <= 32'd0; dbg_romacc <= 32'd0; end
		else begin
			if (rom_stall)                     dbg_romwait <= dbg_romwait + 32'd1;
			if (as_active & sel_rom & ~as_d_r) dbg_romacc  <= dbg_romacc  + 32'd1;
		end
	end

	// ------------------------------------------------------------ memories
	reg [15:0] wram    [0:32767];  // CPU, savestate, back door
	reg [15:0] wram_sp [0:1023];   // copy of Sprite Data (words 0x4000-0x43FF), read by the snapshot
	reg [15:0] pal     [0:1023];   // true dual port: A = CPU/savestate, B = video
	reg [15:0] obj     [0:4095];
	reg [15:0] vr0     [0:8191];
	reg [15:0] vr1     [0:8191];

	wire [14:0] wram_i = a[15:1];
	wire  [9:0] pal_i  = a[10:1];
	wire [11:0] obj_i  = a[12:1];
	wire [12:0] v_i    = a[13:1];
	wire  [8:0] vreg_i = a[9:1];

	wire we  = as_active & ~eRWn;
	// Byte-lane writes wait one clock into the bus cycle so a read-merge sees
	// the word at THIS address (the VRAM's port A below). The write repeats
	// every clock of the cycle, so the extra clock costs nothing.
	wire weq = we & as_d1;
	wire [15:0] wdat = oEdb;
	wire ub = ~UDSn, lb = ~LDSn;
	wire [15:0] ram_wdat = (ub & lb) ? wdat
	                     : ub ? {wdat[15:8], wdat[15:8]}
	                          : {wdat[7:0],  wdat[7:0]};

	// ---- savestate region decode (word addresses; bases aligned to size)
	wire ss_w    = ss_active & ss_wr;
	wire ss_wram = ss_active & (ss_addr[19:15] == 5'h00);   // 0x00000 32768
	wire ss_vr0  = ss_active & (ss_addr[19:13] == 7'h04);   // 0x08000  8192
	wire ss_vr1  = ss_active & (ss_addr[19:13] == 7'h05);   // 0x0A000  8192
	wire ss_pal  = ss_active & (ss_addr[19:10] == 10'h38);  // 0x0E000  1024
	wire ss_obj  = ss_active & (ss_addr[19:12] == 8'h0F);   // 0x0F000  4096
	wire ss_misc = ss_active & (ss_addr[19:4]  == 16'h1D00); // 0x1D000 scalars
	wire ss_park = ss_active & (ss_addr[19:4]  == 16'h1D01); // 0x1D010 68000 park

	wire [14:0] hs_wi   = hs_addr[15:1];
	wire        wsp_cpu = (wram_i[14:10] == 5'b10000);   // word 0x4000-0x43FF
	wire        wsp_ss  = (ss_addr[14:10] == 5'b10000);
	wire        wsp_hs  = (hs_wi[14:10] == 5'b10000);

	always @(posedge clk) begin
		if (ss_w) begin
			if (ss_wram) begin
				wram[ss_addr[14:0]] <= ss_wdata;
				if (wsp_ss) wram_sp[ss_addr[9:0]] <= ss_wdata;
			end
		end else if (hs_access) begin
			// ONE byte: the ram_w mirror belongs to the 68000's write path,
			// and applying it here would corrupt the neighbouring byte.
			if (hs_write) begin
				if (~hs_addr[0]) begin
					wram[hs_wi][15:8] <= hs_din;
					if (wsp_hs) wram_sp[hs_wi[9:0]][15:8] <= hs_din;
				end else begin
					wram[hs_wi][7:0] <= hs_din;
					if (wsp_hs) wram_sp[hs_wi[9:0]][7:0] <= hs_din;
				end
			end
		end else if (we) begin
			if (sel_ram) begin
				wram[wram_i] <= ram_wdat;
				if (wsp_cpu) wram_sp[wram_i[9:0]] <= ram_wdat;
			end
		end
	end

	// Palette and Object RAM take byte writes the same way the VRAM does:
	// the write waits one clock into the bus cycle (weq), by which time the
	// port's own registered read holds this address's word, and the lane not
	// being written is merged back from it. So every write is a full word
	// and every array stays a plain single-write RAM.
	//
	// Quartus 17 did NOT infer these from `mem[a][15:8] <= ..` lane writes --
	// not in the shared block, not in blocks of their own -- and did not say
	// so either: 82 K flip-flops and no "uninferred" message (MS1Z-6). The
	// palette is ONE array in true-dual-port form (A = CPU/savestate, B =
	// video); MS1BCD's two identical copies would be merged back into one
	// three-port array by the synthesiser.
	wire        pal_we = (ss_w & ss_pal) | (weq & sel_pal);
	wire        obj_we = (ss_w & ss_obj) | (weq & sel_obj);
	wire  [9:0] pal_a  = ss_active ? ss_addr[9:0]  : pal_i;
	wire [11:0] obj_a  = ss_active ? ss_addr[11:0] : obj_i;
	wire [15:0] pal_wd = ss_active ? ss_wdata : {ub ? wdat[15:8] : pal_q[15:8], lb ? wdat[7:0] : pal_q[7:0]};
	wire [15:0] obj_wd = ss_active ? ss_wdata : {ub ? wdat[15:8] : obj_q[15:8], lb ? wdat[7:0] : obj_q[7:0]};
	always @(posedge clk) begin
		if (pal_we) begin pal[pal_a] <= pal_wd; pal_q <= pal_wd; end
		else        pal_q <= pal[pal_a];
	end
	always @(posedge clk) pal_rd_data <= pal[pal_rd_addr];
	always @(posedge clk) begin
		if (obj_we) begin obj[obj_a] <= obj_wd; obj_q <= obj_wd; end
		else        obj_q <= obj[obj_a];
	end

	// ---- read ports (registered; address muxed, never concurrent)
	wire [14:0] wram_rd_i = ss_active ? ss_addr[14:0] : hs_access ? hs_wi : wram_i;
	reg  [15:0] wram_q;
	always @(posedge clk) wram_q <= wram[wram_rd_i];
	reg hs_a0_q;
	always @(posedge clk) hs_a0_q <= hs_addr[0];
	assign hs_dout = hs_a0_q ? wram_q[7:0] : wram_q[15:8];

	reg [15:0] pal_q, obj_q;

	// ---- scroll VRAM: true dual port. Port A is the CPU and the savestate
	// (read-or-write, new-data read); port B is the tilemap. A byte write
	// merges with vr*_q, which after the first clock of the cycle holds this
	// address's word (weq).
	wire        v0_we = (ss_w & ss_vr0) | (weq & sel_v0);
	wire        v1_we = (ss_w & ss_vr1) | (weq & sel_v1);
	wire [12:0] v_ai  = ss_active ? ss_addr[12:0] : v_i;
	reg  [15:0] vr0_q, vr1_q;
	wire [15:0] v0_ad = ss_active ? ss_wdata : {ub ? wdat[15:8] : vr0_q[15:8], lb ? wdat[7:0] : vr0_q[7:0]};
	wire [15:0] v1_ad = ss_active ? ss_wdata : {ub ? wdat[15:8] : vr1_q[15:8], lb ? wdat[7:0] : vr1_q[7:0]};
	always @(posedge clk) begin
		if (v0_we) begin vr0[v_ai] <= v0_ad; vr0_q <= v0_ad; end
		else       vr0_q <= vr0[v_ai];
		if (v1_we) begin vr1[v_ai] <= v1_ad; vr1_q <= v1_ad; end
		else       vr1_q <= vr1[v_ai];
	end
	always @(posedge clk) begin
		v0_rd_data <= vr0[v0_rd_addr];
		v1_rd_data <= vr1[v1_rd_addr];
	end

	// ---- the live Sprite Data read port: wram_sp mirrors the 1 K words at
	// work RAM word 0x4000, written with every write to them, so the line
	// renderer reads the list as it stands without a second work-RAM port.
	always @(posedge clk) spr_rq <= wram_sp[spr_ra];

	// ---- video registers: shadows, byte-lane correct, restored by the image
	reg [15:0] sh_scrf, sh_t0x, sh_t0y, sh_t0c, sh_t1x, sh_t1y, sh_t1c;
	function automatic [15:0] merge(input [15:0] old, input [15:0] d, input u, input l);
		merge = {u ? d[15:8] : old[15:8], l ? d[7:0] : old[7:0]};
	endfunction
	wire vw = we & sel_vreg;
	always @(posedge clk) begin
		if (reset) begin
			sh_scrf <= 16'd0;
			sh_t0x <= 16'd0; sh_t0y <= 16'd0; sh_t0c <= 16'd0;
			sh_t1x <= 16'd0; sh_t1y <= 16'd0; sh_t1c <= 16'd0;
		end else if (ss_w & ss_misc) begin
			case (ss_addr[3:0])
				4'd8:  sh_t0x  <= ss_wdata;  4'd9:  sh_t0y <= ss_wdata;
				4'd10: sh_t0c  <= ss_wdata;  4'd11: sh_t1x <= ss_wdata;
				4'd12: sh_t1y  <= ss_wdata;  4'd13: sh_t1c <= ss_wdata;
				4'd14: sh_scrf <= ss_wdata;
				default: ;
			endcase
		end else if (vw) begin
			case (vreg_i)
				9'h100: sh_t0x  <= merge(sh_t0x,  wdat, ub, lb);
				9'h101: sh_t0y  <= merge(sh_t0y,  wdat, ub, lb);
				9'h102: sh_t0c  <= merge(sh_t0c,  wdat, ub, lb);
				9'h104: sh_t1x  <= merge(sh_t1x,  wdat, ub, lb);
				9'h105: sh_t1y  <= merge(sh_t1y,  wdat, ub, lb);
				9'h106: sh_t1c  <= merge(sh_t1c,  wdat, ub, lb);
				9'h180: sh_scrf <= merge(sh_scrf, wdat, ub, lb);
				default: ;
			endcase
		end
	end
	assign reg_screen_flag = sh_scrf;
	assign reg_t0_sx = sh_t0x;  assign reg_t0_sy = sh_t0y;  assign reg_t0_ctrl = sh_t0c;
	assign reg_t1_sx = sh_t1x;  assign reg_t1_sy = sh_t1y;  assign reg_t1_ctrl = sh_t1c;

	// scroll_r: the two scroll triples read back; nothing else in the window
	// has a read handler in MAME, so it reads 0.
	reg [15:0] vreg_rd;
	always @* begin
		case (vreg_i)
			9'h100: vreg_rd = sh_t0x;  9'h101: vreg_rd = sh_t0y;  9'h102: vreg_rd = sh_t0c;
			9'h104: vreg_rd = sh_t1x;  9'h105: vreg_rd = sh_t1y;  9'h106: vreg_rd = sh_t1c;
			default: vreg_rd = 16'h0000;
		endcase
	end

	// ---- inputs. MAME returns 1s for bits a port DECLARES as active-low
	// unknowns and 0s for bits it does not declare at all: SYSTEM and P2
	// declare 0xff00, P1 declares only its low byte.
	reg [15:0] in_rd;
	always @* begin
		case (a[2:1])
			2'd0: in_rd = {8'hFF, in_system};
			2'd1: in_rd = {8'h00, in_p1};
			2'd2: in_rd = {8'hFF, in_p2};
			2'd3: in_rd = {in_dsw2, in_dsw1};
		endcase
	end

	// ---- sound latch: 084308, low byte, one pulse per write cycle
	wire sel_slatch = sel_vreg & (vreg_i == 9'h184);
	reg slatch_d;
	always @(posedge clk) begin
		slatch_d  <= (ss_w & ss_misc & (ss_addr[3:0] == 4'd2)) ? ss_wdata[0] : (we & sel_slatch);
		slatch_we <= (we & sel_slatch) & ~slatch_d;
		if (reset) slatch_data <= 8'h00;
		else if (ss_w & ss_misc & (ss_addr[3:0] == 4'd3)) slatch_data <= ss_wdata[7:0];
		else if ((we & sel_slatch) & ~slatch_d) slatch_data <= wdat[7:0];
	end

	// ---- scalar state
	reg [15:0] ss_misc_rdata;
	always @* begin
		case (ss_addr[3:0])
			4'd1:  ss_misc_rdata = {12'd0, irq3_h, irq2_h, irq1_h, iack_d};
			4'd2:  ss_misc_rdata = {15'd0, slatch_d};
			4'd3:  ss_misc_rdata = {8'd0, slatch_data};
			4'd4:  ss_misc_rdata = {13'd0, phdiv};
			4'd5:  ss_misc_rdata = {14'd0, phase, as_d};
			4'd8:  ss_misc_rdata = sh_t0x;   4'd9:  ss_misc_rdata = sh_t0y;
			4'd10: ss_misc_rdata = sh_t0c;   4'd11: ss_misc_rdata = sh_t1x;
			4'd12: ss_misc_rdata = sh_t1y;   4'd13: ss_misc_rdata = sh_t1c;
			4'd14: ss_misc_rdata = sh_scrf;
			default: ss_misc_rdata = 16'h0000;
		endcase
	end

	always @(posedge clk) begin
		if      (ss_wram) ss_rdata <= wram_q;
		else if (ss_vr0)  ss_rdata <= vr0_q;
		else if (ss_vr1)  ss_rdata <= vr1_q;
		else if (ss_pal)  ss_rdata <= pal_q;
		else if (ss_obj)  ss_rdata <= obj_q;
		else if (ss_park) ss_rdata <= ss_park_rdata;
		else if (ss_misc) ss_rdata <= ss_misc_rdata;
		else              ss_rdata <= 16'h0000;
	end

	// ---- CPU read mux
	reg [15:0] rdat;
	always @* begin
		if      (sel_mon)  rdat = mon_data;
		else if (sel_rom)  rdat = rom_data;
		else if (sel_ram)  rdat = wram_q;
		else if (sel_pal)  rdat = pal_q;
		else if (sel_obj)  rdat = obj_q;
		else if (sel_v0)   rdat = vr0_q;
		else if (sel_v1)   rdat = vr1_q;
		else if (sel_vreg) rdat = vreg_rd;
		else if (sel_in)   rdat = in_rd;
		else               rdat = 16'h0000;
	end
	always @* iEdb = rdat;

	// --------------------------------------------------- interrupt timer
	// HOLD_LINE, and ONE acknowledge cycle retires exactly the level it
	// acknowledged (the 68000 puts it on A3:A1). Level 7 is the savestate
	// park's and retires nothing of the game's (MS1-23).
	reg irq1_h, irq2_h, irq3_h;
	wire iack = ~ASn & (FC0 & FC1 & FC2);
	reg iack_d;
	always @(posedge clk)
		if (ss_w & ss_misc & (ss_addr[3:0] == 4'd1)) iack_d <= ss_wdata[0];
		else iack_d <= iack;
	wire iack_edge = iack & ~iack_d;
	wire [2:0] iack_level = eab[3:1];
	always @(posedge clk) begin
		if (reset) begin
			irq1_h <= 1'b0; irq2_h <= 1'b0; irq3_h <= 1'b0;
			dbg_irq1 <= 0; dbg_irq2 <= 0; dbg_irq3 <= 0;
		end else if (ss_w & ss_misc & (ss_addr[3:0] == 4'd1)) begin
			irq3_h <= ss_wdata[3]; irq2_h <= ss_wdata[2]; irq1_h <= ss_wdata[1];
		end else begin
			if (vtick && vcount == 9'd16)  begin irq3_h <= 1'b1; dbg_irq3 <= dbg_irq3 + 1; end
			if (vtick && vcount == 9'd96)  begin irq1_h <= 1'b1; dbg_irq1 <= dbg_irq1 + 1; end
			if (vtick && vcount == 9'd240) begin irq2_h <= 1'b1; dbg_irq2 <= dbg_irq2 + 1; end
			if (iack_edge) begin
				if (iack_level == 3'd3) irq3_h <= 1'b0;
				if (iack_level == 3'd2) irq2_h <= 1'b0;
				if (iack_level == 3'd1) irq1_h <= 1'b0;
			end
		end
	end

	// ---- savestate: park the 68000. MON_BASE 0x0C0000 is unmapped on this
	// board (nothing between 0x098000 and 0x0F0000).
	wire [2:0]  ipl_park;
	wire        sel_mon;
	wire [15:0] mon_data;
	wire [15:0] ss_park_rdata;
	ss_m68k_park #(.MON_BASE(15'h600)) u_park (
		.clk(clk), .reset(reset), .phi(enPhi2),
		.park_req(ss_freeze), .parked(ss_m68k_parked), .resume(ss_resume),
		.eab(eab), .ASn(ASn), .eRWn(eRWn), .FC0(FC0), .FC1(FC1), .FC2(FC2),
		.oEdb(oEdb),
		.ipl_park(ipl_park), .sel_mon(sel_mon), .mon_data(mon_data),
		.ss_sel(ss_addr[1:0]), .ss_wr(ss_w & ss_park), .ss_wdata(ss_wdata),
		.ss_rdata(ss_park_rdata)
	);

	wire [2:0] ipl_game = irq3_h ? 3'd3 : irq2_h ? 3'd2 : irq1_h ? 3'd1 : 3'd0;
	wire [2:0] ipl = (ipl_park != 3'd0) ? ipl_park : ipl_game;

	// -------------------------------------------------------- bus tracing
	reg as_d;
	always @(posedge clk) begin
		if (reset) begin dbg_acc <= 0; dbg_vregw <= 0; dbg_vramw <= 0; end
		else if (as_active & ~as_d) begin
			dbg_acc <= dbg_acc + 1;
			if (~eRWn & sel_vreg) dbg_vregw <= dbg_vregw + 1;
			if (~eRWn & (sel_v0 | sel_v1)) dbg_vramw <= dbg_vramw + 1;
		end
		if (ss_w & ss_misc & (ss_addr[3:0] == 4'd5)) as_d <= ss_wdata[0];
		else as_d <= as_active;
		tr_valid <= 1'b0;
		// the autovector acknowledge is invisible to MAME's memory tap
		if (as_active & ~as_d & ~iack) begin
			tr_addr  <= a;
			tr_data  <= eRWn ? rdat : oEdb;
			tr_we    <= ~eRWn;
			tr_valid <= 1'b1;
		end
	end

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(enPhi1 & ~pause_68k), .enPhi2(enPhi2 & ~pause_68k),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(VMAn),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(BGn),
		.oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
		// no DTACK during an autovectored acknowledge (VPA instead)
		.DTACKn(~(as_active & ~iack & ~rom_stall & ~arr_wait)), .VPAn(~iack), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
	);
endmodule
