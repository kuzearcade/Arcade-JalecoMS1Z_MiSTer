# video_state (type Z): rtl/jaleco video with BOARD_Z = 1 against one captured
# MAME frame, driven from MAME's own RAM dump (docs/PLAN.md M1 gate).
#   make; tools/mk_video_state_z.py <trace> <F> <dir>; ./obj_dir/Vms1_video <dir> [out.ppm]
RTL := ../../../rtl/jaleco
OBJ := obj_dir
all: $(OBJ)/Vms1_video
$(OBJ)/Vms1_video: $(RTL)/ms1_video.sv $(RTL)/ms1_tilemap.sv $(RTL)/ms1_sprites.sv $(RTL)/ms1_prio.sv tb_video_state.cpp
	verilator --cc --exe --build -O2 -Wall -Wno-fatal --top-module ms1_video \
		-GBOARD_Z=1 -GL0_ROM_MASK=21\'h01FFFF -GL1_ROM_MASK=21\'h00FFFF -GSPR_TILE_MASK=13\'h03FF \
		-y $(RTL) \
		$(RTL)/ms1_video.sv $(RTL)/ms1_tilemap.sv $(RTL)/ms1_sprites.sv $(RTL)/ms1_prio.sv \
		tb_video_state.cpp -o Vms1_video
