/*
    sysctrl.v
 
    generic system control interface from/via the MCU
*/

module sysctrl (
  input		    clk,
  input		    reset,

  input		    data_in_strobe,
  input		    data_in_start,
  input [7:0]	    data_in,
  output reg [7:0]  data_out,

  // interrupt interface
  output	    int_out_n,
  input [7:0]	    int_in,
  output reg [7:0]  int_ack,

  input [1:0]	    buttons, // S0 and S1 buttons on Tang Nano 20k

  output reg [1:0]  leds, // two leds can be controlled from the MCU
  output reg [23:0] color, // a 24bit BRG color to e.g. be used to drive the ws2812

  output reg	    uart_rxd,
  input		    uart_txd,
		
  // values that can be configured by the user		
  output	    system_reset,
  output reg	    system_widescreen,
  output reg	    system_serial_ext,
  output reg	    system_fastboot,
  output reg [1:0]  system_memory,
  output reg [1:0]  system_volume,
  output reg [1:0]  system_floppy_wprot,
  output reg	    system_hdd_wprot
);

reg [3:0] state;
reg [7:0] command;
reg [7:0] id;
   
// reverse data byte for rgb   
wire [7:0] data_in_rev = { data_in[0], data_in[1], data_in[2], data_in[3], 
                           data_in[4], data_in[5], data_in[6], data_in[7] };

reg coldboot = 1'b1;
reg sys_int = 1'b1;

// registers to report button interrupts
reg [1:0] buttonsD, buttonsD2;
reg	  buttons_irq_enable;

// the system control interrupt or any other interrupt (e,g sdc, hid, ...)
// activates the interrupt line to the MCU by pulling it low
assign int_out_n = (int_in != 8'h00 || sys_int)?1'b0:1'b1;

// by default system is in reset
reg main_reset = 1'b1;   
assign system_reset = main_reset;  

reg [31:0] main_reset_timeout;   

// include the menu rom derived from amiga.xml
reg [11:0] menu_rom_addr;
reg  [7:0] menu_rom_data;

// generate hex e.g.: 
// gzip -n macplus.xml
// xxd -c1 -p macplus.xml.gz > macplus_xml.hex
reg [7:0] macplus_xml[1024];
initial $readmemh("macplus_xml.hex", macplus_xml);
   
always @(posedge clk) 
     menu_rom_data <= macplus_xml[menu_rom_addr];

// This should actually reflect what the core has configured
wire [31:0] port_status = { 24'd19200, 4'd8, 2'd0, 2'd1 };
wire [11:0] uart_bit_cnt = (15600000-9600) / 19200;   
   
reg       port_out_availableD;
reg [7:0] port_cmd;   
reg [7:0] port_index;

// port data to be sent to the MCU
reg	   port_out_strobe;

reg	   port_in_strobe;       
reg [7:0]  port_in_data;

// uart receiver, receiving serial from core and sending via spi to MCU
// 16 byte tx buffer to be filled by core
reg [7:0] port_out_buffer[8];
reg [2:0] port_out_rd, port_out_wr;   
wire [7:0] port_out_data = port_out_buffer[port_out_rd];   
wire [7:0] port_out_available = {5'd0, port_out_wr - port_out_rd };   

reg [3:0] uart_tx_state;   
reg [7:0] uart_tx_byte;   
reg [11:0] uart_tx_cnt;

always @(posedge clk) begin
   if(reset) begin
      // initially the buffer is empty
      port_out_rd <= 4'd0;
      port_out_wr <= 4'd0;
      uart_tx_state <= 4'd0;      
   end else begin
      // MCU reads a byte from buffer
      if(port_out_strobe)
	port_out_rd <= port_out_rd + 3'd1;	 

      if(uart_tx_state == 4'd0) begin
	 // idle state: wait for falling data edge
	 if(!uart_txd) begin
	    uart_tx_cnt <= {1'b0, uart_bit_cnt[11:1]};   // half bit time
	    uart_tx_state <= 4'd1;                       // wait for first data bit	    
	 end
      end else if(uart_tx_cnt == 12'd0) begin
	 // data state: receive one byte incl. start and stop bits	 
	 uart_tx_cnt <= uart_bit_cnt;             // full bit time
	 uart_tx_state <= uart_tx_state + 4'd1;   // wait for next data bit

	 if(uart_tx_state <= 4'd9) begin
	    // receive start bit and 8 data bits
	    uart_tx_byte <= { uart_txd, uart_tx_byte[7:1] };
	 end else begin
	    // TODO: check stop bit

	    // received one full byte
	    port_out_buffer[port_out_wr] <= uart_tx_byte;
	    port_out_wr <= port_out_wr + 3'd1;	 
	    
	    uart_tx_state <= 4'd0;	    
	 end

      end else
	uart_tx_cnt <= uart_tx_cnt - 12'd1;
   end
end

// uart transmitter, receiving spi data from MCU and sending it serialized into core

reg [3:0] uart_rx_state;   
reg [7:0] uart_rx_byte;   
reg [11:0] uart_rx_cnt;
   
// 8 byte rx buffer to be filled by MCU
reg [7:0] port_in_buffer[8];
reg [2:0] port_in_rd, port_in_wr;   
wire [7:0] port_in_available = {5'd0, port_in_rd - port_in_wr - 3'd1 };   

always @(posedge clk) begin
   if(reset) begin
      // initially the buffer is empty
      port_in_rd <= 3'd0;
      port_in_wr <= 3'd0;      
      uart_rx_state <= 4'd0;   
      uart_rxd <= 1'b1;        // idle state
   end else begin
      // buffer bytes received from MCU
      if(port_in_strobe && (port_in_available != 8'd0)) begin
	 port_in_buffer[port_in_wr] <= port_in_data;	 
	 port_in_wr <= port_in_wr + 3'd1;	 
      end

      // transmit bytes as serial data
      if(uart_rx_state == 4'd0) begin
	 // idle start: start transmitting once a byte has arrived
	 if(port_in_rd != port_in_wr) begin
	    // fetch received byte from buffer
	    uart_rx_byte <= port_in_buffer[port_in_rd];
	    port_in_rd <= port_in_rd + 3'd1;
	    uart_rx_state <= 4'd1;

	    // and start transmitting
	    uart_rxd <= 1'b0;            // start bit
	    uart_rx_cnt <= uart_bit_cnt; // full bit time
	 end
      end else if(uart_rx_cnt == 12'd0) begin
	 uart_rx_cnt <= uart_bit_cnt; 
	 uart_rx_state <= uart_rx_state + 4'd1;   // transmit next data bit

	 // send 8 data bits and stop bit
	 if(uart_rx_state <= 9) begin
	    uart_rxd <= uart_rx_byte[0];
	    uart_rx_byte <= { 1'b1, uart_rx_byte[7:1] };
	 end else
	   uart_rx_state <= 4'd0;  // done sending after stop bit

      end else
	uart_rx_cnt <= uart_rx_cnt - 12'd1;      
   end
end   
   
// process mouse events
always @(posedge clk) begin  
   if(reset) begin
      state <= 4'd0;      
      leds <= 2'b00;        // after reset leds are off
      color <= 24'h000000;  // color black -> rgb led off

      // stay in reset for about 3 seconds or until MCU releases reset
      main_reset <= 1'b1;   
      main_reset_timeout <= 32'd86_000_000;      

      buttons_irq_enable <= 1'b1;  // allow buttons irq
      int_ack <= 8'h00;
      coldboot = 1'b1;      // reset is actually the power-on-reset
      sys_int = 1'b1;       // coldboot interrupt

      port_out_strobe <= 1'b0;
      port_in_strobe <= 1'b0;

      // OSD value defaults. These should be sane defaults, but the MCU
      // will very likely override these early
      system_widescreen <= 1'b0;           // normal screen by default      
      system_serial_ext <= 1'b0;           // redirect serial to wifi by default
      system_memory <= 2'd1;               // 512k
      system_volume <= 2'd1;               // volume low
      system_fastboot <= 1'b0;             // normal boot
      system_floppy_wprot <= 2'b11;        // both disks write protected
      system_hdd_wprot <= 1'b1;            // SCSI write protected
   end else begin // if (reset)
      //  bring button state into local clock domain
      buttonsD <= buttons;
      buttonsD2 <= buttonsD;

      // release main reset after timeout
      if(main_reset_timeout) begin
	 main_reset_timeout <= main_reset_timeout - 32'd1;

	 if(main_reset_timeout == 32'd1) begin
	    main_reset <= 1'b0;

	    // BRG LED yellow if no MCU has responded
	    color <= 24'h000202;
	 end
      end
      
      int_ack <= 8'h00;
      port_out_strobe <= 1'b0;
      port_in_strobe <= 1'b0;

      // iack bit 0 acknowledges the coldboot notification
      if(int_ack[0]) sys_int <= 1'b0;      

      // (further) data has just become available, so raise interrupt
      port_out_availableD <= (port_out_available != 8'd0);
      if((port_out_available != 8'd0) && !port_out_availableD)
	sys_int <= 1'b1;      
      
      // monitor buttons for changes and raise interrupt
      if(buttons_irq_enable) begin
        if(buttonsD2 != buttonsD) begin
            // irq_enable prevents further interrupts until
            // the button state has actually been read by the MCU
            sys_int <= 1'b1;
            buttons_irq_enable <= 1'b0;
        end
      end
     
      if(data_in_strobe) begin      
        if(data_in_start) begin
            state <= 4'd0;
            command <= data_in;
	    menu_rom_addr <= 12'h000;
            data_out <= 8'h00;
        end else begin
            if(state != 4'd15) state <= state + 4'd1;
	    
            // CMD 0: status data
            if(command == 8'd0) begin
                // return some pattern that would not appear randomly
	        // on e.g. an unprogrammed device
                if(state == 4'd0) data_out <= 8'h5c;   // \ magic marker to identify a valid
                if(state == 4'd1) data_out <= 8'h42;   // / FPGA core
                if(state == 4'd2) data_out <= 8'h00;   // core id 0 = Generic core
            end
	   
            // CMD 1: there are two MCU controlled LEDs
            if(command == 8'd1) begin
                if(state == 4'd0) leds <= data_in[1:0];
            end

            // CMD 2: a 24 color value to be mapped e.g. onto the ws2812
            if(command == 8'd2) begin
                if(state == 4'd0) color[15: 8] <= data_in_rev;
                if(state == 4'd1) color[ 7: 0] <= data_in_rev;
                if(state == 4'd2) color[23:16] <= data_in_rev;
            end

            // CMD 3: return button state
            if(command == 8'd3) begin
               data_out <= { 6'b000000, buttons };;
	       // re-enable interrupt once state has been read
               buttons_irq_enable <= 1'b1;
            end

            // CMD 4: config values (e.g. set by user via OSD)
            if(command == 8'd4) begin
               // second byte can be any character which identifies the variable to set 
               if(state == 4'd0) id <= data_in;

	       // Mac/Nanomac specific control values
               if(state == 4'd1) begin
                   // Value "R": reset(1) or run(0)
                   if(id == "R") begin
		      main_reset <= data_in[0];
		      // cancel out-timeout if MCU is active
		      main_reset_timeout <= 32'd0;
		   end
		   
		   // Value "Y": Memory 128k(0), 512k(1), 1M(2) or 2M(3)
		   if(id == "Y") system_memory <= data_in[1:0];
		   // Value "V": Volume off(0), low(1), mid(2) or high(3)
		   if(id == "V") system_volume <= data_in[1:0];
		   // Value "W": Floppy write protect int (0) and ext (1)
		   if(id == "W") system_floppy_wprot <= data_in[1:0];
		   // Value "X": Normal(0) or Wide(1) screen
		   if(id == "X") system_widescreen <= data_in[0];
		   // Value "S": HDD write protect enabled
		   if(id == "S") system_hdd_wprot <= data_in[0];
		   // Value "F": fastboot off(0) or on(1), disables rom and ram checks
		   if(id == "F") system_fastboot <= data_in[0];
		   // Value "M": serial modem port redirect to WiFi(0) or external/MIDI(1)
		   if(id == "M") system_serial_ext <= data_in[0];
                end
            end

            // CMD 5: interrupt control
            if(command == 8'd5) begin
                // second byte acknowleges the interrupts
                if(state == 4'd0) int_ack <= data_in;

	        // interrupt[0] notifies the MCU of a FPGA cold boot e.g. if
                // the FPGA has been loaded via USB
                data_out <= { int_in[7:1], sys_int };
            end
	   
            // CMD 6: read system interrupt source
            if(command == 8'd6) begin
                // bit[0]: coldboot flag
	        // bit[2]: buttons state change has been detected
                data_out <= { 5'b0000, !buttons_irq_enable, (port_out_available != 8'd0), coldboot };
                // reading the interrupt source acknowledges the coldboot notification
                if(state == 4'd0) coldboot <= 1'b0;            
            end

	    // CMD 7: port in/out
            if(command == 8'd7) begin
               // the first two bytes of a port command always have the same meaning ...
               if(state == 4'd0) begin
                  // first byte is the subcommand
                  port_cmd <= data_in;
                  // return the number of ports implemented in this core
                  data_out <= 8'd1;
               end else if(state == 4'd1) begin
                  // second byte is the port index (if several ports are supported)
                  port_index <= data_in;
                  // return port type (currently supports only 0=serial)
                  data_out <= 8'd0;
               end else begin
                  // ... further bytes are subcommand specific

                  // port subcommand 0: get status
                  if(port_cmd == 8'd0 && port_index == 8'd0) begin
                     if(state == 4'd2)       data_out <= port_out_available;
                     else if(state == 4'd3)  data_out <= port_in_available;
                     // port status for type 0 (serial) is still close to the format
                     // that was introduced with the first MiST
                     else if(state == 4'd4)  data_out <= port_status[31:24];  // bitrate[7:0]
                     else if(state == 4'd5)  data_out <= port_status[23:16];  // bitrate[15:8]
                     else if(state == 4'd6)  data_out <= port_status[15:8];   // bitrate[23:16]
                     else if(state == 4'd7)  data_out <= port_status[7:0];    // databits, parity and stopbits
                     else                    data_out <= 8'h00;
                  end
                  
                  // port subcommand 1: read port data
                  else if(port_cmd == 8'd1 && port_index == 8'd0) begin
                     data_out <= port_out_data;

                     // reading the byte ack's the mfp's fifo. Since the
                     // data arrives with one byte delay at the MCU we need
                     // to make sure that the last read will not trigger
                     // another fifo read. The MCU will thus not set bit[0] for
                     // the last read to suppress the fifo read
                     port_out_strobe <= data_in[0];
                  end
                  
                  // port subcommand 2: write port data
                  else if(port_cmd == 8'd2 && port_index == 8'd0) begin
                     port_in_data <= data_in;
                     port_in_strobe <= 1'b1;
                  end
                  
               end
            end // if (command == 8'd7)
	   
            // CMD 8: read (menu) config
            if(command == 8'd8) begin
	       data_out <= menu_rom_data;
	       menu_rom_addr <= menu_rom_addr + 12'd1;		  
	    end
         end
      end
   end
end
    
endmodule
