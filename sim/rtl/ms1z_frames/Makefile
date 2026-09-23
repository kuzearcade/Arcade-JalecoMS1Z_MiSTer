# Reference simulation of the whole Mega System 1-Z board (LOOKAHEAD 0, ROMs
# served from zero-latency arrays). ./obj_dir/Vms1z_core <imgdir> <frames>
RTL := ../../../rtl
V := verilator --cc --exe --build -O3 -CFLAGS -O3 --x-assign fast --x-initial fast -Wall -Wno-fatal \
	-Wno-DECLFILENAME -Wno-UNUSED -Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-TIMESCALEMOD \
	-Wno-VARHIDDEN -Wno-CASEINCOMPLETE -Wno-GENUNNAMED -Wno-BLKANDNBLK -Wno-SYNCASYNCNET \
	-Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-LATCH -Wno-PINMISSING -Wno-IMPLICIT -Wno-CASEOVERLAP \
	-Wno-COMBDLY -Wno-SELRANGE -Wno-UNDRIVEN -Wno-ASCRANGE
# Every file -y can pull in is a prerequisite (MS1-58).
RTLSRC := $(wildcard $(RTL)/*.sv $(RTL)/ms1z/*.sv $(RTL)/ms1z/*.vh $(RTL)/jaleco/*.sv $(RTL)/savestate/*.sv)
all: obj_dir/Vms1z_core
obj_dir/Vms1z_core: tb.cpp $(RTLSRC)
	$(V) --top-module ms1z_core -I$(RTL)/ms1z \
		-y $(RTL)/ms1z -y $(RTL)/jaleco -y $(RTL)/savestate -y $(RTL)/third_party/fx68k \
		-y $(RTL)/third_party/jt12/hdl -y $(RTL)/third_party/jt12/jt49/hdl \
		-y $(RTL)/third_party/jt12/hdl/mixer \
		$(RTL)/ms1z/ms1z_core.sv $(RTL)/ms1z/ms1z_main.sv $(RTL)/ms1z/ms1z_sound.sv \
		$(RTL)/jaleco/ms1_video.sv $(RTL)/jaleco/ms1_tilemap.sv $(RTL)/jaleco/ms1_sprites.sv \
		$(RTL)/jaleco/ms1_prio.sv \
		$(RTL)/savestate/ss_m68k_park.sv $(RTL)/savestate/ss_z80_park.sv \
		$(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv \
		$(RTL)/third_party/fx68k/uaddrPla.sv \
		$(RTL)/third_party_gen/t80/T80s.v $(RTL)/third_party/jt12/hdl/jt03.v \
		tb.cpp -o Vms1z_core
	cp -f $(RTL)/third_party/fx68k/microrom.mem $(RTL)/third_party/fx68k/nanorom.mem .

# MAME's own timing, for the gates only (417 x 256 at 6 MHz = 56.18 Hz;
# docs/known-issues.md MS1Z-5). Never shipped.
mame: obj_mame/Vms1z_core
obj_mame/Vms1z_core: tb.cpp $(RTLSRC)
	$(V) --Mdir obj_mame -GHTOTAL=417 -GVTOTAL=256 --top-module ms1z_core -I$(RTL)/ms1z \
		-y $(RTL)/ms1z -y $(RTL)/jaleco -y $(RTL)/savestate -y $(RTL)/third_party/fx68k \
		-y $(RTL)/third_party/jt12/hdl -y $(RTL)/third_party/jt12/jt49/hdl \
		-y $(RTL)/third_party/jt12/hdl/mixer \
		$(RTL)/ms1z/ms1z_core.sv $(RTL)/ms1z/ms1z_main.sv $(RTL)/ms1z/ms1z_sound.sv \
		$(RTL)/jaleco/ms1_video.sv $(RTL)/jaleco/ms1_tilemap.sv $(RTL)/jaleco/ms1_sprites.sv \
		$(RTL)/jaleco/ms1_prio.sv \
		$(RTL)/savestate/ss_m68k_park.sv $(RTL)/savestate/ss_z80_park.sv \
		$(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv \
		$(RTL)/third_party/fx68k/uaddrPla.sv \
		$(RTL)/third_party_gen/t80/T80s.v $(RTL)/third_party/jt12/hdl/jt03.v \
		tb.cpp -o Vms1z_core
