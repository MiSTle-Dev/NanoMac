//============================================================================
//  Macintosh Plus
//
//  Port to MiSTer
//  Copyright (C) 2017-2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module macplus
(
	//Master input clock
	input		       CLKIN,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input		       RESET,

        // video and audio outputs
        output		       pixelOut,
	output		       vsync,
	output		       hsync,

	output [11:0]	       audio,

	output [4:0]	       leds,

	//ADC
	inout [3:0]	       ADC_BUS,

        //MOUSE
	input [5:0]	       MOUSE,
	input		       kbd_strobe,
	input [9:0]	       kbd_data,

        // set the real-world inputs to sane defaults
	input		       configROMSize,     // 64k or 128K ROM
	input		       configFastboot,    // disable rom/ram check
	input [1:0]	       configRAMSize,     // 128k, 512k, 1MB or 4MB
	input		       configMachineType, // 0 = Plus, 1 = SE
	input [1:0]	       configFloppyWProt,
	input		       configSCSIWProt,
			  
        // interface to sd card
	input [31:0]	       sdc_image_size,
	input [SCSI_DEVS+1:0]  sdc_image_mounted,
	output [31:0]	       sdc_lba,
	output [SCSI_DEVS+1:0] sdc_rd,
	output [SCSI_DEVS+1:0] sdc_wr,
	input		       sdc_done,
	input		       sdc_busy,
	output [7:0]	       sdc_data_out,
	input [7:0]	       sdc_data_in,
	input		       sdc_data_en,
	input [8:0]	       sdc_addr,

        // serial port
	output		       UART_TXD,
	input		       UART_RXD,
	output		       UART_RTS,
	input		       UART_CTS,

        // interface to toplevel rom
	output		       _romOE,
        output [17:0]	       romAddr, 
        input [15:0]	       romData, 

	output [2:0]	       busPhase, // used to synchronize ram state machine
  
        // interface to (sd)ram
	output [20:0]	       ram_addr,
	output [15:0]	       sdram_din,
	output [1:0]	       sdram_ds,
	output		       sdram_we,
	output		       sdram_oe,
	input [15:0]	       sdram_do
);

assign ADC_BUS  = 'Z;

////////////////////   CLOCKS   ///////////////////

wire clk_sys = CLKIN;

wire clk8_en_p, clk8_en_n;
wire videoBusControl;
wire cpuBusControl;
   
clocks clocks (
       .clk             ( clk_sys         ),
       .clk8_en_p       ( clk8_en_p       ),
       .clk8_en_n       ( clk8_en_n       ),
       .busPhase        ( busPhase        ),
       .videoBusControl ( videoBusControl ),
       .cpuBusControl   ( cpuBusControl   )
);
   

reg       n_reset = 0;
always @(posedge clk_sys) begin
	reg [15:0] rst_cnt;

	if (clk8_en_p) begin
		// various sources can reset the mac
		if(RESET || ~_cpuReset_o ) begin
			rst_cnt <= '1;
			n_reset <= 0;
		end
		else if(rst_cnt) begin
			rst_cnt    <= rst_cnt - 1'd1;
		end
		else begin
			n_reset <= 1;
		end
	end
end

// Blank screen during reset. Otherwise the image
// would freeze during reset which looks somehow confusing
wire pixel;   
assign pixelOut = n_reset?pixel:1'b0;  
   
///////////////////////////////////////////////////

localparam SCSI_DEVS = 2;

// the status register is controlled by the on screen display (OSD)
wire  [1:0] buttons;
wire [32:0] TIMESTAMP;

//
// Serial Ports
//
wire serialOut;
wire serialIn = UART_RXD;
wire serialRTS;
wire serialCTS = UART_CTS;

assign UART_TXD = serialOut;
assign UART_RTS = serialRTS;

// interconnects
// CPU
wire _cpuReset, _cpuReset_o, _cpuUDS, _cpuLDS, _cpuRW;
wire _cpuAS;
wire _cpuVMA, _cpuVPA, _cpuDTACK;
wire E_rising, E_falling;
wire [2:0] _cpuIPL;
wire [2:0] cpuFC;
wire [23:1] cpuAddr;
wire [15:0] cpuDataOut;

// RAM/ROM
wire _ramOE, _ramWE;
wire _memoryUDS, _memoryLDS;

// peripherals
wire vid_alt, loadPixels, _hblank, _vblank;
wire memoryOverlayOn, selectSCSI, selectSCC, selectIWM, selectVIA, selectRAM, selectROM, selectSEOverlay;
wire [15:0] dataControllerDataOut;

// audio
wire snd_alt;
wire loadSound;

// only accept /AS for ram or rom if it comes in phase 2. Don't accept any later as as we would not
// be able to complete the bus cycle
reg     _cpuAS_I;   
always @(posedge clk_sys) begin
   if(busPhase == 2) _cpuAS_I <= _cpuAS; // this allows for a full bus cycle
   if(busPhase == 7 && _cpuAS) _cpuAS_I <= 1'b1;
end

wire _cpuAS_R = !(!_cpuAS && !_cpuAS_I);   
   
assign      _cpuVPA = (cpuFC == 3'b111) ? 1'b0 : ~(!_cpuAS && selectVIA);

// only ram access limited to CPU cycle. Everything else also in video cycle
// furthermore allow cpu ram access in unused video cycles.
wire	refreshCycle;
   
// Make sure, we never end a memory cycle before the memory was able to return data
wire	cpuBusCycleDone = busPhase >= 4;
wire	cpuOnVideoBusControl = !loadPixels && !loadSound && !refreshCycle && videoBusControl && !_cpuAS && selectRAM;   
assign      _cpuDTACK = ~((!_cpuAS_R && selectRAM && cpuBusControl && cpuBusCycleDone) ||
			  (!_cpuAS_R && selectRAM && cpuOnVideoBusControl && cpuBusCycleDone) ||
			  (!_cpuAS_R && selectROM && cpuBusCycleDone) ||
                          (!_cpuAS && !selectVIA && !selectRAM && !selectROM)); // everything else but the VIA

fx68k fx68k (
	.clk        ( clk_sys ),
	.extReset   ( !_cpuReset ),
	.pwrUp      ( !_cpuReset ),
	.enPhi1     ( clk8_en_p   ),
	.enPhi2     ( clk8_en_n   ),

	.eRWn       ( _cpuRW ),
	.ASn        ( _cpuAS ),
	.LDSn       ( _cpuLDS ),
	.UDSn       ( _cpuUDS ),
	.E          ( ),
	.E_div      ( 1'b0 ),
	.E_PosClkEn ( E_falling ),
	.E_NegClkEn ( E_rising ),
	.VMAn       ( _cpuVMA ),
	.FC0        ( cpuFC[0] ),
	.FC1        ( cpuFC[1] ),
	.FC2        ( cpuFC[2] ),
	.BGn        ( ),
	.oRESETn    ( _cpuReset_o ),
	.oHALTEDn   ( ),
	.DTACKn     ( _cpuDTACK ),
	.VPAn       ( _cpuVPA ),
`ifndef VERILATOR
	.HALTn      ( 1'b1 ),
`endif
	.BERRn      ( 1'b1 ),
	.BRn        ( 1'b1 ),
	.BGACKn     ( 1'b1 ),
	.IPL0n      ( _cpuIPL[0] ),
	.IPL1n      ( _cpuIPL[1] ),
	.IPL2n      ( _cpuIPL[2] ),
	.iEdb       ( dataControllerDataOut ),
	.oEdb       ( cpuDataOut ),
	.eab        ( cpuAddr )
);

addrController ac0
(
	.clk(clk_sys),
	.clk8_en_p(clk8_en_p),
	.clk8_en_n(clk8_en_n),
	.cpuAddr(cpuAddr), 
	._cpuUDS(_cpuUDS),
	._cpuLDS(_cpuLDS),
	._cpuRW(_cpuRW),
	._cpuAS(_cpuAS),
	.configROMSize({configMachineType,~configMachineType}),
	.configRAMSize(configRAMSize), 
	.romAddr(romAddr),
	.ramAddr(ram_addr),
	._memoryUDS(_memoryUDS),
	._memoryLDS(_memoryLDS),
	._romOE(_romOE), 
	._ramOE(_ramOE), 
	._ramWE(_ramWE),
	.videoBusControl(videoBusControl),	
	.cpuBusControl(cpuBusControl),	
	.cycleReady(busPhase == 3'd7),
	.selectSCSI(selectSCSI),
	.selectSCC(selectSCC),
	.selectIWM(selectIWM),
	.selectVIA(selectVIA),
	.selectRAM(selectRAM),
	.selectROM(selectROM),
	.selectSEOverlay(selectSEOverlay),
	.hsync(hsync), 
	.vsync(vsync),
	._hblank(_hblank),
	._vblank(_vblank),
	.loadPixels(loadPixels),
	.vid_alt(vid_alt),
	.memoryOverlayOn(memoryOverlayOn),
	.refresh(refreshCycle),

	.snd_alt(snd_alt),
	.loadSound(loadSound)
);

/* fastboot patches the rom check and the ramcheck away */
wire [15:0] romDataMod =
	    configFastboot?romDataPatched:
	    romData;   

wire	    trigger = (cpuAddr == 0);   
   
wire [15:0] romDataPatched =
	    ({ romAddr, 1'b0 } == 18'hd7a)?16'h6022:   // 7000, disable rom checksum test
	    ({ romAddr, 1'b0 } == 18'hea8)?16'h4e71:   // 6EEC, shorten ram test read
	    ({ romAddr, 1'b0 } == 18'he90)?16'h4e71:   // 6AF0, shorten ram test write
	    romData;
   
dataController #(SCSI_DEVS) dc0
(
	.clk(clk_sys), 
	.clk8_en_p(clk8_en_p),
	.clk8_en_n(clk8_en_n),
	.E_rising(E_rising),
	.E_falling(E_falling),
	.machineType(configMachineType),
	.floppy_wprot(configFloppyWProt),
	.scsi_wprot(configSCSIWProt),
	._systemReset(n_reset),
	._cpuReset(_cpuReset), 
	._cpuIPL(_cpuIPL),
	._cpuUDS(_cpuUDS), 
	._cpuLDS(_cpuLDS), 
	._cpuRW(_cpuRW), 
	._cpuVMA(_cpuVMA),
	.cpuDataIn(cpuDataOut),
	.cpuDataOut(dataControllerDataOut), 	
	.cpuAddrRegHi(cpuAddr[12:9]),
	.cpuAddrRegMid(cpuAddr[6:4]),  // for SCSI
	.cpuAddrRegLo(cpuAddr[2:1]),		
	.selectSCSI(selectSCSI),
	.selectSCC(selectSCC),
	.selectIWM(selectIWM),
	.selectVIA(selectVIA),
	.selectSEOverlay(selectSEOverlay),
	.cpuBusControl(cpuBusControl),
	.videoBusControl(videoBusControl),
	.cycleReady(busPhase == 3'd7),
	.memoryDataOut(sdram_din),
        .romSel(!_romOE), 
	.ramDataIn(sdram_do),
	.romDataIn(romDataMod),

        // interface to sd card
	.sdc_img_mounted( sdc_image_mounted ),
	.sdc_img_size( sdc_image_size ),
        .sdc_lba     ( sdc_lba      ),
	.sdc_rd      ( sdc_rd       ),
	.sdc_wr      ( sdc_wr       ),
	.sdc_busy    ( sdc_busy     ),
	.sdc_done    ( sdc_done     ),
	.sdc_data_in ( sdc_data_in  ),
        .sdc_data_out( sdc_data_out ),
	.sdc_data_en ( sdc_data_en  ),
	.sdc_addr    ( sdc_addr     ),
	 
	// peripherals
	.mouse(MOUSE),
        .kbd_strobe(kbd_strobe),
	.kbd_data(kbd_data),
 
	// serial uart
	.serialIn(serialIn),
	.serialOut(serialOut),
	.serialCTS(serialCTS),
	.serialRTS(serialRTS),

	// rtc unix ticks
	.timestamp(TIMESTAMP),

	// video
	._hblank(_hblank),
	._vblank(_vblank), 
	.pixelOut(pixel),
	.loadPixels(loadPixels),
	.vid_alt(vid_alt),

	.memoryOverlayOn(memoryOverlayOn),

	.audioOut(audio),
	.snd_alt(snd_alt),
	.loadSound(loadSound),

	// floppy disk interface
	.diskLED(leds)
);

////////////////////////// SDRAM /////////////////////////////////

assign sdram_ds   = { !_memoryUDS, !_memoryLDS };
assign sdram_we   = !_ramWE;
assign sdram_oe   = !_ramOE;

endmodule
