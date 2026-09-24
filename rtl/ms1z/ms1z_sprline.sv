// Mega System 1-Z sprites, drawn a LINE at a time from live Sprite Data.
//
// Why not MS1BCD's frame plane (docs/known-issues.md MS1Z-12): lomakai
// rewrites its sprite list during the first ~100 raster lines of every frame,
// and MAME's type Z draws sprites from live work RAM at render time, so a
// frame shows the list written during that same frame. A plane drawn from a
// vblank snapshot can only show it a frame later: the sprites trailed the
// background by one scroll step. This draws the row the NEXT raster line will
// show while the current one is on screen, from Sprite Data as it stands
// then -- as close as a raster can get to "what the RAM says when the beam
// arrives".
//
// Drawing rules are megasys1_typez_state::draw_sprites exactly (MS1Z-7):
//   entries 127 down to 0; the first opaque pixel at a spot keeps it
//   (prio_transpen's implicit bit 31), so the HIGHEST index is in front;
//   attr = word 4 (bit 7 flip Y, bit 6 flip X, bits 3:0 colour),
//   x = sext9(word 5), y = sext9(word 6), code = word 7 modulo TILE_MASK+1;
//   16 x 16, pen 15 transparent; clipped to x 0..255.
// Screen flip is not handled here: ms1_video mirrors its read point (rot180,
// MS1-13), so this always draws the UNFLIPPED bitmap row the display will
// read next -- `row` below follows the flip for that reason only.
//
// Line buffer: 2 x 256 entries of {pri=0, colour, pen}, ping-pong in one M10K
// (port A written here, port B read by the display), plus 2 x 256 occupancy
// flip-flops, which is what makes "first writer wins" and the per-line clear
// (256 bits in one clock) cheap.
//
// Budget: one raster line, 3072 clocks. Scanning costs 3 per entry (384);
// a sprite on the row costs ~6 to read and 3 per ROM byte (8 bytes) with a
// warm cache. A row not finished when the line ends is cut short (the
// remaining, lower-indexed sprites are dropped) and counted in dbg_overruns.
module ms1z_sprline #(
	parameter [12:0] TILE_MASK = 13'h03FF,
	parameter [8:0]  VTOTAL    = 9'd278
) (
	input               clk,
	input               reset,

	input               vtick,        // one pulse at the end of each raster line
	input        [8:0]  vcount,       // the raster line (updates after vtick)
	input               flip,         // screen_flag[0] ^ OSD flip

	// Sprite Data, live: work RAM words 0x4000-0x43FF, REGISTERED read
	// (data valid two clocks after the address is set here).
	output reg   [9:0]  spr_ra,
	input       [15:0]  spr_rq,

	// sprite ROM, byte addressed; rom_data valid when rom_ready for rom_addr
	output reg  [21:0]  rom_addr,
	input        [7:0]  rom_data,
	input               rom_ready,

	// display side: {y, x} of the bitmap point being read, one-clock readback
	input       [15:0]  fb_rd_addr,
	output       [8:0]  fb_q,

	output reg  [31:0]  dbg_overruns,
	output reg  [15:0]  dbg_max_hits,
	output reg  [15:0]  dbg_max_cycles
);
	// ------------------------------------------------------------ buffers
	reg        dh;                         // half the display reads
	reg  [8:0] lb [0:511];
	reg  [255:0] occ0, occ1;
	reg        lb_we;
	reg  [8:0] lb_wa;
	reg  [8:0] lb_wd;
	always @(posedge clk) if (lb_we) lb[lb_wa] <= lb_wd;
	reg  [8:0] lb_q;
	reg        occ_q;
	always @(posedge clk) begin
		lb_q  <= lb[{dh, fb_rd_addr[7:0]}];
		occ_q <= dh ? occ1[fb_rd_addr[7:0]] : occ0[fb_rd_addr[7:0]];
	end
	assign fb_q = occ_q ? lb_q : 9'h00F;

	// ------------------------------------------------------------ renderer
	localparam [3:0] S_IDLE = 4'd0, S_START = 4'd1, S_SCAN = 4'd2, S_SW = 4'd3,
	                 S_CHK = 4'd4, S_H1 = 4'd5, S_H2 = 4'd6, S_H3 = 4'd7,
	                 S_H4 = 4'd8, S_BWAIT = 4'd9, S_P0 = 4'd10, S_P1 = 4'd11,
	                 S_DONE = 4'd12;
	reg  [3:0] st;
	reg  [6:0] s;               // entry, 127 down to 0
	reg  [7:0] row;             // bitmap row being drawn
	reg  [3:0] gy;              // source row inside the tile
	reg  [2:0] k;               // source byte 0..7 of that row
	reg  [3:0] col;
	reg        fx, fy;
	reg signed [9:0] sx;
	reg [12:0] tile;
	reg  [7:0] byte_q;
	reg [15:0] attr;
	reg [15:0] hits, cycles;
	wire       rh = ~dh;        // half being drawn

	wire signed [9:0] sy   = {spr_rq[8], spr_rq[8:0]};
	wire signed [10:0] dy  = $signed({3'b000, row}) - $signed({sy[9], sy});
	wire       on_row      = (dy >= 0) && (dy < 16);

	// Byte k of source row gy: 128 bytes per tile, two 8-wide column halves
	// (k[2] selects the right half, +64), 4 bytes per row, 2 pixels per byte
	// -- the layout ms1_sprites.sv and MAME's gfx_8x8x4_col_2x2 use.
	wire [2:0]  kn = k + 3'd1;
	// source x of the two pixels of byte k, and where they land
	wire [3:0] gx0 = {k, 1'b0};
	wire [3:0] gx1 = {k, 1'b1};
	wire [3:0] dx0 = fx ? ~gx0 : gx0;
	wire [3:0] dx1 = fx ? ~gx1 : gx1;
	wire signed [10:0] px0 = {sx[9], sx} + {7'd0, dx0};
	wire signed [10:0] px1 = {sx[9], sx} + {7'd0, dx1};
	wire [3:0] pen0 = byte_q[7:4];
	wire [3:0] pen1 = byte_q[3:0];
	wire in0 = (px0 >= 0) && (px0 < 256);
	wire in1 = (px1 >= 0) && (px1 < 256);
	wire occ_r0 = rh ? occ1[px0[7:0]] : occ0[px0[7:0]];
	wire occ_r1 = rh ? occ1[px1[7:0]] : occ0[px1[7:0]];

	// vtick marks the LAST pixel of raster line L-1 (vcount has not advanced
	// yet). At that point the half just drawn is shown for line L, and the
	// row to draw now is the one line L+1 will read: vcount + 2.
	wire [8:0] vnext = (vcount == VTOTAL - 9'd2) ? 9'd0
	                 : (vcount == VTOTAL - 9'd1) ? 9'd1 : vcount + 9'd2;

	wire [7:0] rowi = flip ? (8'd255 - vnext[7:0]) : vnext[7:0];

	reg start;
	always @(posedge clk) start <= vtick;

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; dh <= 1'b0; occ0 <= 256'd0; occ1 <= 256'd0;
			dbg_overruns <= 32'd0; dbg_max_hits <= 16'd0; dbg_max_cycles <= 16'd0;
		end else begin
			if (st != S_IDLE) cycles <= cycles + 16'd1;
			if (start) begin
				// the line just drawn goes on screen; begin the next one
				if (st != S_IDLE && st != S_DONE) dbg_overruns <= dbg_overruns + 32'd1;
				dh <= ~dh;
				st <= S_START;
			end else case (st)
			S_START: begin
				// dh has flipped: rh is now the half to draw into
				if (rh) occ1 <= 256'd0; else occ0 <= 256'd0;
				row    <= rowi;
				s      <= 7'd127;
				hits   <= 16'd0; cycles <= 16'd0;
				spr_ra <= {7'd127, 3'd6};
				// Only bitmap rows 16..239 are ever displayed (either way up:
				// flipped, raster line L reads row 255-L). Anything else is
				// skipped -- e.g. at power-up every entry is at y = 0, which
				// is 128 sprites on rows 0..15 and far more than a line holds.
				st     <= (rowi >= 8'd16 && rowi < 8'd240) ? S_SW : S_DONE;
			end
			// scan: word 6 of entry s, two clocks after its address
			S_SCAN: begin spr_ra <= {s, 3'd6}; st <= S_SW; end
			S_SW:   st <= S_CHK;
			S_CHK: begin
				if (on_row) begin
					gy     <= dy[3:0];
					hits   <= hits + 16'd1;
					spr_ra <= {s, 3'd4};             // attr
					st     <= S_H1;
				end else if (s == 7'd0) st <= S_DONE;
				else begin s <= s - 7'd1; spr_ra <= {s - 7'd1, 3'd6}; st <= S_SW; end
			end
			S_H1: begin spr_ra <= {s, 3'd5}; st <= S_H2; end          // x
			S_H2: begin attr <= spr_rq; spr_ra <= {s, 3'd7}; st <= S_H3; end   // code
			S_H3: begin
				sx  <= {spr_rq[8], spr_rq[8:0]};
				col <= attr[3:0]; fx <= attr[6]; fy <= attr[7];
				if (attr[7]) gy <= ~gy;
				st  <= S_H4;
			end
			S_H4: begin
				tile <= spr_rq[12:0] & TILE_MASK;
				k    <= 3'd0;
				st   <= S_BWAIT;
				rom_addr <= ({9'd0, spr_rq[12:0] & TILE_MASK} << 7) + ({18'd0, gy} << 2);
			end
			S_BWAIT: if (rom_ready) begin byte_q <= rom_data; st <= S_P0; end
			S_P0: begin
				if (in0 && pen0 != 4'hF && !occ_r0) begin
					lb_we <= 1'b1; lb_wa <= {rh, px0[7:0]}; lb_wd <= {1'b0, col, pen0};
					if (rh) occ1[px0[7:0]] <= 1'b1; else occ0[px0[7:0]] <= 1'b1;
				end
				st <= S_P1;
			end
			S_P1: begin
				if (in1 && pen1 != 4'hF && !occ_r1) begin
					lb_we <= 1'b1; lb_wa <= {rh, px1[7:0]}; lb_wd <= {1'b0, col, pen1};
					if (rh) occ1[px1[7:0]] <= 1'b1; else occ0[px1[7:0]] <= 1'b1;
				end
				if (k == 3'd7) begin
					if (s == 7'd0) st <= S_DONE;
					else begin s <= s - 7'd1; spr_ra <= {s - 7'd1, 3'd6}; st <= S_SW; end
				end else begin
					k <= k + 3'd1;
					rom_addr <= ({9'd0, tile} << 7) + (kn[2] ? 22'd64 : 22'd0)
					          + ({18'd0, gy} << 2) + {20'd0, kn[1:0]};
					st <= S_BWAIT;
				end
			end
			S_DONE: begin
				if (hits > dbg_max_hits) dbg_max_hits <= hits;
				if (cycles > dbg_max_cycles) dbg_max_cycles <= cycles;
				st <= S_IDLE;
			end
			default: st <= S_IDLE;
			endcase
		end
	end
endmodule
