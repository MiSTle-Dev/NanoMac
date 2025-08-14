// nanomacxs simulation top

module nanomac_tb
  (
   input	    clk, // 16/32mhz
   input	    reset,
   output reg [2:0] phase, 

   input [1:0]	    ram_size,
   input	    fastboot,
   
   output [4:0]	    leds,
   
   // serial output, mainly for diagrom
   output	    uart_tx,

   // video
   output	    hs_n,
   output	    vs_n,
   output	    pix,
   output [11:0]    audio,

   output	    _romOE,
   output [17:0]    romAddr, 
   input [15:0]	    romData, 

   // keyboard
   input	    kbd_strobe,
   input [7:0]	    kbd_data, 
   
   // interface to sd card
   input [31:0]	    image_size, // length of image file
   input [3:0]	    image_mounted, // two floppy drives, two scsi drives

   // low level sd card interface
   output	    sdclk,
   output	    sdcmd,
   input	    sdcmd_in,
   output [3:0]	    sddat,
   input [3:0]	    sddat_in,
   
   // sdram interface
   output	    sd_clk, // sd clock
   output	    sd_cke, // clock enable
   output [31:0]    sd_data_out, // 32 bit bidirectional data bus
   input [31:0]	    sd_data_in,
   output [10:0]    sd_addr, // 11 bit multiplexed address bus
   output [3:0]	    sd_dqm, // two byte masks
   output [1:0]	    sd_ba, // two banks
   output	    sd_cs, // a single chip select
   output	    sd_we, // write enable
   output	    sd_ras, // row address select
   output	    sd_cas, // columns address select

   // serial interface
   output	    uart_txd,
   input	    uart_rxd,
   
   // interface to sdram controller
   output	    sdram_oe,
   output	    sdram_we,
   output [1:0]	    sdram_ds,
   output [20:0]    ram_addr,
   output [15:0]    sdram_din,
   input [15:0]	    sdram_do
   );

wire		    ram_ready;   
wire [15:0]	    sdram_dout;
   
sdram sdram (
             .clk(clk),               // sdram is accessed at 16MHz
             .reset_n(!reset),        // init signal after FPGA config to initialize RAM
	     
	     .sd_clk(sd_clk),         // sd clock
             .sd_cke(sd_cke),         // clock enable
             .sd_data(sd_data_out),   // 32 bit bidirectional data bus
             .sd_data_in(sd_data_in),
             .sd_addr(sd_addr),       // 11 bit multiplexed address bus
             .sd_dqm(sd_dqm),         // four byte masks
             .sd_ba(sd_ba),           // four banks
             .sd_cs(sd_cs),           // a single chip select
             .sd_we(sd_we),           // write enable
             .sd_ras(sd_ras),         // row address select
             .sd_cas(sd_cas),         // columns address select

             // cpu/chipset interface
             .ready(ram_ready),       // ram is ready and has been initialized
             .phase(phase),           // bus cycle phase to sync to
             .din(sdram_din),         // data input from chipset/cpu
             .dout(sdram_dout),       // data output to chipset/cpu
             .addr({1'b0, ram_addr}), // 22 bit word address
             .ds(~sdram_ds),          // upper/lower data strobe
             .oe(sdram_oe),           // cpu/chipset requests read/wrie
             .we(sdram_we)            // cpu/chipset requests write
);   

// for floppy IO the SD card itself may be included into the simulation or not
wire [7:0]       sdc_rd;
wire [7:0]       sdc_wr;
wire [31:0]      sdc_lba;
wire             sdc_busy;
wire             sdc_done;
wire             sdc_data_en;
wire [8:0]       sdc_addr;
wire [7:0]       sdc_data_in;
wire [7:0]       sdc_data_out;

// TODO: map different "drives" into different areas of the SD card
   
// for now only floppy uses this to address up to 1MB
assign sdc_lba[31:24] = sdc_rd | sdc_wr;
assign sdc_rd[7:4] = 4'b0000;
assign sdc_wr[7:4] = 4'b0000;   
   
sd_rw #(
    .CLK_DIV(3'd1),
    .SIMULATE(1'b1)
) sd_card (
    .rstn(!reset),                 // rstn active-low, 1:working, 0:reset
    .clk(clk),                     // clock

    // SD card signals
    .sdclk(sdclk),
    .sdcmd(sdcmd),
    .sdcmd_in(sdcmd_in),
    .sddat(sddat),
    .sddat_in(sddat_in),

    // user read sector command interface (sync with clk)
    .rstart(|sdc_rd), 
    .wstart(|sdc_wr), 
    .sector(sdc_lba),
    .rbusy(sdc_busy),
    .rdone(sdc_done),
                 
    // sector data output interface (sync with clk)
    .inbyte(sdc_data_out),
    .outen(sdc_data_en),    // when outen=1, a byte of sector content is read out from outbyte
    .outaddr(sdc_addr),     // outaddr from 0 to 511, because the sector size is 512
    .outbyte(sdc_data_in)   // a byte of sector content
);

macplus macplus (
        //Master input clock
        .CLKIN(clk),

        //Async reset from top-level module.
        //Can be used as initial reset.
        .RESET(reset || !ram_ready),

        .pixelOut(pix),
        .hsync(hs_n),
        .vsync(vs_n),

        .audio(audio),

	.configROMSize(1'b1),       // 64k or 128K ROM
	.configFastboot(fastboot),  // disable rom/ram check
	.configRAMSize(ram_size),   // 128k, 512k, 1MB or 4MB
	.configMachineType(1'b0),   // Plus, SE
	.configFloppyWProt(2'b00),  // no write protection

        .leds(leds),

        //ADC
        .ADC_BUS(),

        //MOUSE + Keyboard
        .MOUSE(5'b11111),
        .kbd_strobe(kbd_strobe),
        .kbd_data(kbd_data),

        // interface to sd card
	.sdc_image_size( image_size),
	.sdc_image_mounted( image_mounted ),
	.sdc_lba     ( sdc_lba[23:0] ),        // upper 8 bist are mapped to command bits
	.sdc_rd      ( sdc_rd[3:0] ),
	.sdc_wr      ( sdc_wr[3:0] ),
	.sdc_busy    ( sdc_busy    ),
	.sdc_done    ( sdc_done    ),
	.sdc_data_in ( sdc_data_in ),
 	.sdc_data_out( sdc_data_out),
	.sdc_data_en ( sdc_data_en ),
	.sdc_addr    ( sdc_addr    ),
	 
	._romOE(_romOE),
	.romAddr(romAddr),
	.romData(romData),
		 
         // interface to (sd)ram
	.busPhase(phase),
	.ram_addr(ram_addr),
	.sdram_din(sdram_din),
	.sdram_ds(sdram_ds),
	.sdram_we(sdram_we),
	.sdram_oe(sdram_oe),
	.sdram_do(sdram_dout), // sdram_do (sim sram), sdram_dout = (sim sdram)
 
        .UART_TXD(uart_txd),
        .UART_RXD(uart_rxd),
        .UART_RTS(),
        .UART_CTS(1'b1)
);

endmodule
