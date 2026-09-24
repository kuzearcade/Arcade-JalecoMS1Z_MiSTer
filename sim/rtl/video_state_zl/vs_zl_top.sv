// video_state for the MS1-Z LINE renderer: ms1_video (EXT_SPR) + ms1z_sprline,
// paced by the real 384 x 278 raster so the renderer gets its one-line budget.
module vs_zl_top (
	input clk, input reset, input ce, input vtick,
	input [8:0] hcount, input [8:0] vcount, input vvalid,
	input [15:0] t0_sx, t0_sy, t0_ctrl, t1_sx, t1_sy, t1_ctrl, screen_flag,
	output [12:0] l0_vram_addr, l1_vram_addr, input [15:0] l0_vram_data, l1_vram_data,
	output [20:0] l0_rom_addr, l1_rom_addr, input [7:0] l0_rom_data, l1_rom_data,
	output [9:0] spr_ra, input [15:0] spr_rq,
	output [21:0] spr_rom_addr, input [7:0] spr_rom_data,
	output [9:0] pal_addr, input [15:0] pal_data,
	output [23:0] rgb, output rgb_valid,
	output [31:0] overruns, output [15:0] max_hits, max_cycles
);
	wire [15:0] fa; wire [8:0] fq;
	ms1z_sprline #(.TILE_MASK(13'h03FF), .VTOTAL(9'd278)) u_sl (
		.clk(clk), .reset(reset), .vtick(vtick), .vcount(vcount), .flip(screen_flag[0]),
		.spr_ra(spr_ra), .spr_rq(spr_rq),
		.rom_addr(spr_rom_addr), .rom_data(spr_rom_data), .rom_ready(1'b1),
		.fb_rd_addr(fa), .fb_q(fq),
		.dbg_overruns(overruns), .dbg_max_hits(max_hits), .dbg_max_cycles(max_cycles));
	ms1_video #(.TOTAL_W(384), .BOARD_Z(1), .L0_ROM_MASK(21'h01FFFF), .L1_ROM_MASK(21'h00FFFF),
	            .SPR_TILE_MASK(13'h03FF), .EXT_SPR(1)) u_v (
		.clk(clk), .ce(ce), .reset(reset), .mode(2'd0), .nlayers(2'd2), .osd_flip(1'b0),
		.spr_buf_busy(1'b0), .active_layers(16'h000B), .sprite_flag(16'd0), .sprite_bank(16'd0),
		.screen_flag(screen_flag),
		.t0_sx(t0_sx), .t0_sy(t0_sy), .t0_ctrl(t0_ctrl), .t1_sx(t1_sx), .t1_sy(t1_sy), .t1_ctrl(t1_ctrl),
		.t2_sx(16'd0), .t2_sy(16'd0), .t2_ctrl(16'd0),
		.vx(hcount), .vy(vcount - 9'd16), .vvalid(vvalid),
		.l0_vram_addr(l0_vram_addr), .l1_vram_addr(l1_vram_addr), .l2_vram_addr(),
		.l0_vram_data(l0_vram_data), .l1_vram_data(l1_vram_data), .l2_vram_data(16'd0),
		.l0_rom_addr(l0_rom_addr), .l1_rom_addr(l1_rom_addr), .l2_rom_addr(),
		.l0_rom_use_addr(), .l1_rom_use_addr(), .l2_rom_use_addr(),
		.l0_rom_data(l0_rom_data), .l1_rom_data(l1_rom_data), .l2_rom_data(8'hFF),
		.spr_start(1'b0), .spr_busy(), .obj_addr(), .spr_ram_addr(), .obj_data(16'd0), .spr_ram_data(16'd0),
		.spr_rom_addr(), .spr_rom_data(8'd0), .spr_rom_ready(1'b1), .ss_rst_dbg(1'b0),
		.ss_active(1'b0), .ss_addr(20'd0), .ss_wr(1'b0), .ss_wdata(16'd0), .ss_spr_rdata(),
		.dbg_o0(), .dbg_o2(), .dbg_spr_pass_cycles(), .dbg_spr_late_swaps(),
		.prom_addr(), .prom_data(8'd0), .pal_addr(pal_addr), .pal_data(pal_data),
		.rgb(rgb), .rgb_valid(rgb_valid), .dbg_pal_idx(), .ext_fb_rd_addr(fa), .ext_fb_q(fq));
endmodule
