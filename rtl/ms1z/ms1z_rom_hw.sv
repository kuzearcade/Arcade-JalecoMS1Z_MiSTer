// The SDRAM side of the Mega System 1-Z core: the ioctl download, the Z80's
// program window, and a cache in front of every ROM the core reads.
//
// Derived from Arcade-JalecoMS1BCD_MiSTer's rtl/ms1bcd/ms1bcd_rom_hw.sv. The
// sound 68000, the MCU and both OKIs are gone; the Z80's 16 KB window is
// copied into block RAM inside ms1z_sound as the ROM streams past, so the
// Z80 never waits on a cache (NMK16's worst Z80 bug class was a busy-poll
// chain whose termination depended on a cache's fill timing). The whole
// 64 KB region is still written to SDRAM, which is what the golden-byte
// audit walks.
//
// Port allocation over rtl/sdram.sv's four physical ports:
//   0   main 68000 program  +  the ioctl download
//   1   scroll layers 0 and 1
//   2   sprites
//   3   unused
module ms1z_rom_hw (
	input               clk,
	input               reset,
	input               pwr_reset,     // power-on only (SS-15)

	input               ioctl_download,
	input        [7:0]  ioctl_index,
	input               ioctl_wr,
	input       [26:0]  ioctl_addr,
	input        [7:0]  ioctl_dout,
	output              ioctl_wait,

	input       [16:0]  rom_addr,      // main 68000, word address
	output      [15:0]  rom_data,
	output              rom_ready,

	input       [20:0]  l0_rom_addr, l1_rom_addr,
	input       [20:0]  l0_rom_use_addr, l1_rom_use_addr,
	output       [7:0]  l0_rom_data, l1_rom_data,
	output              l0_ready, l1_ready,

	input       [21:0]  spr_rom_addr,
	output       [7:0]  spr_rom_data,
	output              spr_ready,

	// the Z80 window, as the download streams it
	output reg          zrom_we,
	output reg  [13:0]  zrom_waddr,
	output reg   [7:0]  zrom_wdata,

	// golden-byte audit: 0 main, 3 L0, 4 L1, 6 sprites
	input               audit_en,
	input        [3:0]  audit_sel,
	input       [23:0]  audit_addr,
	output reg  [15:0]  audit_data,
	output reg          audit_ready,

	output      [24:1]  sdram_addr0, sdram_addr1, sdram_addr2, sdram_addr3,
	output              sdram_wrl0,  sdram_wrl1,  sdram_wrl2,  sdram_wrl3,
	output              sdram_wrh0,  sdram_wrh1,  sdram_wrh2,  sdram_wrh3,
	output      [15:0]  sdram_din0,  sdram_din1,  sdram_din2,  sdram_din3,
	input       [15:0]  sdram_dout0, sdram_dout1, sdram_dout2, sdram_dout3,
	input       [31:0]  sdram_pair0, sdram_pair1, sdram_pair2, sdram_pair3,
	output              sdram_req0,  sdram_req1,  sdram_req2,  sdram_req3,
	input               sdram_ack0,  sdram_ack1,  sdram_ack2,  sdram_ack3,

	output reg  [31:0]  dbg_dl_bytes,
	output reg  [31:0]  dbg_zrom_bytes
);
	`include "ms1z_rom_map.vh"

	// ------------------------------------------------------------ download
	// Only index 0 reaches SDRAM: <switches> (254) restarts at address 0 and
	// ungated would land on the reset vector. Index 1 carries the board's two
	// PROMs, which this core does not use (they are not a priority PROM --
	// docs/known-issues.md MS1Z-2); they are accepted and dropped.
	wire dl_rom = ioctl_download && (ioctl_index == 8'd0);

	reg         dl_req;
	reg  [24:1] dl_addr;
	reg  [15:0] dl_din;
	reg         dl_wrl, dl_wrh;
	wire        dl_busy, dl_valid;
	always @(posedge clk) begin
		if (pwr_reset) begin
			dl_req <= 1'b0; dl_wrl <= 1'b0; dl_wrh <= 1'b0;
			dbg_dl_bytes <= 32'd0;
		end else begin
			if (dl_valid) dl_req <= 1'b0;
			if (dl_rom && ioctl_wr && !dl_req) begin
				dl_addr <= ioctl_addr[24:1];
				dl_din  <= {ioctl_dout, ioctl_dout};
				dl_wrl  <= ~ioctl_addr[0];
				dl_wrh  <=  ioctl_addr[0];
				dl_req  <= 1'b1;
				dbg_dl_bytes <= dbg_dl_bytes + 32'd1;
			end
		end
	end
	assign ioctl_wait = dl_req;

	// The Z80 window rides the same accepted byte.
	wire [26:0] z_off = ioctl_addr - {3'd0, SND_BASE};
	always @(posedge clk) begin
		zrom_we <= 1'b0;
		if (pwr_reset) dbg_zrom_bytes <= 32'd0;
		else if (dl_rom && ioctl_wr && !dl_req && (ioctl_addr >= {3'd0, SND_BASE})
		         && (z_off < 27'h4000)) begin
			zrom_we    <= 1'b1;
			zrom_waddr <= z_off[13:0];
			zrom_wdata <= ioctl_dout;
			dbg_zrom_bytes <= dbg_zrom_bytes + 32'd1;
		end
	end

	wire cache_reset = reset | ioctl_download;

	wire [16:0] a_main = audit_en ? audit_addr[16:0] : rom_addr;
	wire [23:0] a_l0   = audit_en ? audit_addr : {3'd0, l0_rom_addr};
	wire [23:0] a_l1   = audit_en ? audit_addr : {3'd0, l1_rom_addr};
	wire [23:0] ua_l0  = audit_en ? audit_addr : {3'd0, l0_rom_use_addr};
	wire [23:0] ua_l1  = audit_en ? audit_addr : {3'd0, l1_rom_use_addr};
	wire [23:0] a_spr  = audit_en ? audit_addr : {2'd0, spr_rom_addr};

	// The download puts the even byte in the LOW lane, which every byte cache
	// wants; the 68000 wants it HIGH, so its word is swapped here (MS1BCD
	// rom_hw, docs/PLAN.md 4.A.5).
	wire [15:0] main_word;
	assign rom_data = {main_word[7:0], main_word[15:8]};

	always @* begin
		case (audit_sel)
			4'd0: begin audit_data = rom_data;             audit_ready = rom_ready; end
			4'd3: begin audit_data = {8'd0, l0_rom_data};  audit_ready = l0_ready;  end
			4'd4: begin audit_data = {8'd0, l1_rom_data};  audit_ready = l1_ready;  end
			4'd6: begin audit_data = {8'd0, spr_rom_data}; audit_ready = spr_ready; end
			default: begin audit_data = 16'd0;             audit_ready = 1'b1;      end
		endcase
	end

	// =============================================== port 0: main + download
	wire [24:1] p0_addr [0:1];  wire p0_we [0:1];  wire p0_wrl [0:1];
	wire        p0_wrh  [0:1];  wire [15:0] p0_din [0:1];
	wire        p0_req  [0:1];  wire p0_busy [0:1]; wire p0_valid [0:1];
	wire [15:0] p0_dout [0:1];  wire [31:0] p0_pair [0:1];

	rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h3FFFFF)) u_main (
		.clk(clk), .reset(cache_reset),
		.addr({MAIN_BASE[23:1] + {6'd0, a_main}}),
		.data(main_word), .ready(rom_ready),
		.sd_addr(p0_addr[0]), .sd_req(p0_req[0]),
		.sd_busy(p0_busy[0]), .sd_valid(p0_valid[0]),
		.sd_dout(p0_dout[0]), .sd_dout_pair(p0_pair[0])
	);
	assign p0_we[0] = 1'b0; assign p0_wrl[0] = 1'b0; assign p0_wrh[0] = 1'b0;
	assign p0_din[0] = 16'd0;
	assign p0_addr[1] = dl_addr;  assign p0_req[1] = dl_req;
	assign p0_we[1]   = 1'b1;     assign p0_wrl[1] = dl_wrl;
	assign p0_wrh[1]  = dl_wrh;   assign p0_din[1] = dl_din;
	assign dl_busy    = p0_busy[1];
	assign dl_valid   = p0_valid[1];

	sdram_arb #(.N(2)) u_arb0 (
		.clk(clk), .reset(pwr_reset),
		.i_addr(p0_addr), .i_we(p0_we), .i_wrl(p0_wrl), .i_wrh(p0_wrh),
		.i_din(p0_din), .i_req(p0_req), .i_busy(p0_busy),
		.i_valid(p0_valid), .i_dout(p0_dout), .i_dout_pair(p0_pair),
		.sdram_addr(sdram_addr0), .sdram_wrl(sdram_wrl0), .sdram_wrh(sdram_wrh0),
		.sdram_din(sdram_din0), .sdram_dout(sdram_dout0),
		.sdram_dout_pair(sdram_pair0), .sdram_req(sdram_req0), .sdram_ack(sdram_ack0)
	);

	// ================================================ port 1: layers 0 and 1
	wire [24:1] p1_addr [0:1];  wire p1_we [0:1];  wire p1_wrl [0:1];
	wire        p1_wrh  [0:1];  wire [15:0] p1_din [0:1];
	wire        p1_req  [0:1];  wire p1_busy [0:1]; wire p1_valid [0:1];
	wire [15:0] p1_dout [0:1];  wire [31:0] p1_pair [0:1];

	tile_prefetch_byte #(.TAG_W(19), .ENTRIES(16)) u_l0 (
		.clk(clk), .reset(cache_reset),
		.base_word(L0_BASE[23:1]),
		.pf_tag(a_l0[20:2]), .pf_byte_addr(a_l0), .pf_vram(16'd0),
		.use_tag(ua_l0[20:2]), .use_sel(ua_l0[1:0]),
		.data(l0_rom_data), .vram(), .hit(l0_ready),
		.sd_addr(p1_addr[0]), .sd_req(p1_req[0]),
		.sd_busy(p1_busy[0]), .sd_valid(p1_valid[0]),
		.sd_dout(p1_dout[0]), .sd_dout_pair(p1_pair[0])
	);
	tile_prefetch_byte #(.TAG_W(19), .ENTRIES(16)) u_l1 (
		.clk(clk), .reset(cache_reset),
		.base_word(L1_BASE[23:1]),
		.pf_tag(a_l1[20:2]), .pf_byte_addr(a_l1), .pf_vram(16'd0),
		.use_tag(ua_l1[20:2]), .use_sel(ua_l1[1:0]),
		.data(l1_rom_data), .vram(), .hit(l1_ready),
		.sd_addr(p1_addr[1]), .sd_req(p1_req[1]),
		.sd_busy(p1_busy[1]), .sd_valid(p1_valid[1]),
		.sd_dout(p1_dout[1]), .sd_dout_pair(p1_pair[1])
	);
	assign p1_we[0] = 1'b0; assign p1_wrl[0] = 1'b0; assign p1_wrh[0] = 1'b0; assign p1_din[0] = 16'd0;
	assign p1_we[1] = 1'b0; assign p1_wrl[1] = 1'b0; assign p1_wrh[1] = 1'b0; assign p1_din[1] = 16'd0;

	sdram_arb #(.N(2)) u_arb1 (
		.clk(clk), .reset(cache_reset),
		.i_addr(p1_addr), .i_we(p1_we), .i_wrl(p1_wrl), .i_wrh(p1_wrh),
		.i_din(p1_din), .i_req(p1_req), .i_busy(p1_busy),
		.i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_pair),
		.sdram_addr(sdram_addr1), .sdram_wrl(sdram_wrl1), .sdram_wrh(sdram_wrh1),
		.sdram_din(sdram_din1), .sdram_dout(sdram_dout1),
		.sdram_dout_pair(sdram_pair1), .sdram_req(sdram_req1), .sdram_ack(sdram_ack1)
	);

	// ======================================================= port 2: sprites
	// Behind an arbiter even with one consumer: the cache HOLDS its request
	// until data arrives, and a bare port wants a pulse (SS-12 #3).
	wire [24:1] p2_addr [0:0];  wire p2_we [0:0];  wire p2_wrl [0:0];
	wire        p2_wrh  [0:0];  wire [15:0] p2_din [0:0];
	wire        p2_req  [0:0];  wire p2_busy [0:0]; wire p2_valid [0:0];
	wire [15:0] p2_dout [0:0];  wire [31:0] p2_pair [0:0];
	rom_cache_n_byte #(.LINES(8), .PREFETCH(1)) u_spr (
		.clk(clk), .reset(cache_reset),
		.base_word(SPR_BASE[23:1]), .byte_addr(a_spr),
		.data(spr_rom_data), .word(), .ready(spr_ready),
		.sd_addr(p2_addr[0]), .sd_req(p2_req[0]),
		.sd_busy(p2_busy[0]), .sd_valid(p2_valid[0]),
		.sd_dout(p2_dout[0]), .sd_dout_pair(p2_pair[0])
	);
	assign p2_we[0] = 1'b0; assign p2_wrl[0] = 1'b0; assign p2_wrh[0] = 1'b0; assign p2_din[0] = 16'd0;
	sdram_arb #(.N(1)) u_arb2 (
		.clk(clk), .reset(cache_reset),
		.i_addr(p2_addr), .i_we(p2_we), .i_wrl(p2_wrl), .i_wrh(p2_wrh),
		.i_din(p2_din), .i_req(p2_req), .i_busy(p2_busy),
		.i_valid(p2_valid), .i_dout(p2_dout), .i_dout_pair(p2_pair),
		.sdram_addr(sdram_addr2), .sdram_wrl(sdram_wrl2), .sdram_wrh(sdram_wrh2),
		.sdram_din(sdram_din2), .sdram_dout(sdram_dout2),
		.sdram_dout_pair(sdram_pair2), .sdram_req(sdram_req2), .sdram_ack(sdram_ack2)
	);

	// ====================================================== port 3: unused
	assign sdram_addr3 = 24'd0; assign sdram_wrl3 = 1'b0; assign sdram_wrh3 = 1'b0;
	assign sdram_din3 = 16'd0;  assign sdram_req3 = 1'b0;
endmodule
