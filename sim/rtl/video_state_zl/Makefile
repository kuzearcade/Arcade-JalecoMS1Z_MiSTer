# video_state for the MS1-Z line renderer (MS1Z-12): ms1_video EXT_SPR + ms1z_sprline
# against one MAME frame, real raster pacing. ./obj_dir/Vvs_zl_top <dir from tools/mk_video_state_z.py>
RTL := ../../../rtl
all: obj_dir/Vvs_zl_top
obj_dir/Vvs_zl_top: vs_zl_top.sv tb.cpp $(RTL)/jaleco/ms1_video.sv $(RTL)/jaleco/ms1_tilemap.sv $(RTL)/jaleco/ms1_prio.sv $(RTL)/ms1z/ms1z_sprline.sv
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-PINCONNECTEMPTY --top-module vs_zl_top \
		-y $(RTL)/jaleco -y $(RTL)/ms1z vs_zl_top.sv tb.cpp -o Vvs_zl_top
