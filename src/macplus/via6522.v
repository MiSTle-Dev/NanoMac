//-----------------------------------------------------------------------------
// Title      : VIA 6522
//-----------------------------------------------------------------------------
// Author     : Gideon Zweijtzer  <gideon.zweijtzer@gmail.com>
//-----------------------------------------------------------------------------
// Description: This module implements the 6522 VIA chip.
//              A LOT OF REVERSE ENGINEERING has been done to make this module
//              as accurate as it is now. Thanks to gyurco for ironing out some
//              differences that were left unnoticed.
//-----------------------------------------------------------------------------
// License:     GPL 3.0 - Free to use, distribute and change to your own needs.
//              Leaving a reference to the author will be highly appreciated.
//-----------------------------------------------------------------------------

module via6522 (
    input clock,
    input rising,
    input falling,
    input reset,
    
    input [3:0] addr,
    input wen,
    input ren,
    input [7:0] data_in,
    output reg [7:0] data_out,

    output reg phi2_ref,

    // -- pio --
    output [7:0] port_a_o,
    output [7:0] port_a_t,
    input [7:0] port_a_i,
    
    output [7:0] port_b_o,
    output [7:0] port_b_t,
    input [7:0] port_b_i,

    // -- handshake pins
    input ca1_i,

    output ca2_o,
    input ca2_i,
    output ca2_t,
    
    output cb1_o,
    input cb1_i,
    output cb1_t,
    
    output cb2_o,
    input cb2_i,
    output cb2_t,

    output irq
);

reg [7:0] pra;
reg [7:0] ddra;
reg [7:0] prb;
reg [7:0] ddrb;

wire [15:0] latch_reset_pattern = 16'h5550;
wire [7:0]  last_data = 8'h55;
    
reg [7:0] port_a_c = 8'h00;
reg [7:0] port_b_c = 8'h00;

reg [6:0] irq_mask = 8'h00;
reg [6:0] irq_flags = 8'h00;
wire [6:0] irq_events;   
wire irq_out;
   
reg [15:0] timer_a_latch = latch_reset_pattern;
reg [15:0] timer_b_latch = latch_reset_pattern;
reg [15:0] timer_a_count = latch_reset_pattern;
reg [15:0] timer_b_count = latch_reset_pattern;
wire	   timer_a_out;
reg	   timer_b_tick;

reg [7:0] acr = 8'h00;   
reg [7:0] pcr = 8'h00;
reg [7:0] shift_reg = 8'h00;
reg	   serport_en;
reg	   ser_cb2_o;
wire	   hs_cb2_o;
reg	   cb1_t_int;
reg	   cb1_o_int;
reg	   cb2_t_int;
reg	   cb2_o_int;
   
reg [7:0] ira = 8'h00;
reg [7:0] irb = 8'h00;

reg write_t1c_l;
reg write_t1c_h;
reg write_t2c_h;
   
reg ca1_c, ca2_c;
reg cb1_c, cb2_c;
reg ca1_d, ca2_d;
reg cb1_d, cb2_d;
   
reg ca2_handshake_o;
reg ca2_pulse_o;
reg cb2_handshake_o;
reg cb2_pulse_o;
reg shift_active;
   
assign irq = irq_out;
    
assign write_t1c_l = (addr == 4'h4 || addr == 4'h6) && wen && falling;
assign write_t1c_h = addr == 4'h5 && wen && falling;
assign write_t2c_h = addr == 4'h9 && wen && falling;

assign irq_events[1] = (ca1_c != ca1_d) && (ca1_d != pcr[0]);
assign irq_events[0] = (ca2_c != ca2_d) && (ca2_d != pcr[2]);
assign irq_events[4] = (cb1_c != cb1_d) && (cb1_d != pcr[4]);
assign irq_events[3] = (cb2_c != cb2_d) && (cb2_d != pcr[6]);

assign ca2_t = pcr[3];
assign cb2_t_int = serport_en?acr[4]:pcr[7];
assign cb2_o_int = serport_en?ser_cb2_o:hs_cb2_o;

assign cb1_t = cb1_t_int;
assign cb1_o = cb1_o_int;
assign cb2_t = cb2_t_int;
assign cb2_o = cb2_o_int;

assign ca2_o = (pcr[2:1] == 2'b00)?ca2_handshake_o:
	       (pcr[2:1] == 2'b01)?ca2_pulse_o:
	       (pcr[2:1] == 2'b10)?1'b0:
	       1'b1;
        
assign hs_cb2_o = (pcr[6:5] == 2'b00)?cb2_handshake_o:
		  (pcr[6:5] == 2'b01)?cb2_pulse_o:
		  (pcr[6:5] == 2'b10)?1'b0:
		  1'b1;

assign irq_out = ((irq_flags & irq_mask) == 7'b0000000)?1'b0:1'b1;  

always @(posedge clock) begin
   if(rising)       phi2_ref <= 1'b1;
   else if(falling) phi2_ref <= 1'b0;
end

always @(posedge clock) begin
   if(reset) begin
      pra  <= 8'h00;
      ddra <= 8'h00;
      prb  <= 8'h00;
      ddrb <= 8'h00;
      irq_mask <= 7'b0000000;
      irq_flags <= 7'b0000000;
      acr <= 8'h00; // TODO
      pcr <= 8'h00;
      ca2_handshake_o <= 1'b1;
      ca2_pulse_o     <= 1'b1;
      cb2_handshake_o <= 1'b1;
      cb2_pulse_o     <= 1'b1;
      timer_a_latch  <= latch_reset_pattern;
      timer_b_latch  <= latch_reset_pattern;
   end else begin // if (reset)
      // CA1/CA2/CB1/CB2 edge detect flipflops
      ca1_c <= ca1_i;
      ca2_c <= ca2_i;      
      if(!cb1_t_int) cb1_c <= cb1_i;
      else           cb1_c <= cb1_o_int;
      if(!cb2_t_int) cb2_c <= cb2_i;
      else           cb2_c <= cb2_o_int;

      ca1_d <= ca1_c;
      ca2_d <= ca2_c;
      cb1_d <= cb1_c;
      cb2_d <= cb2_c;
      
      // input registers
      port_a_c <= port_a_i;
      port_b_c <= port_b_i;

      // input latch emulation
      if(!acr[0] || irq_events[1]) ira <= port_a_c;
      if(!acr[1] || irq_events[4]) irb <= port_b_c;

      // CA2 logic
      if(irq_events[1])
        ca2_handshake_o <= 1'b1;
      else if ((ren || wen ) && addr == 4'h1 && falling)
        ca2_handshake_o <= 1'b0;
            
      if(falling) begin
         if ((ren || wen ) && addr == 4'h1)
           ca2_pulse_o <= 1'b0;
         else            
           ca2_pulse_o <= 1'b1;
      end
      
      // CB2 logic
      if(irq_events[4])
        cb2_handshake_o <= 1'b1;
      else if ((ren || wen) && addr == 4'h0 && falling)
        cb2_handshake_o <= 1'b0;

      if(falling) begin
         if ((ren || wen ) && addr == 4'h0)
           cb2_pulse_o <= 1'b0;
         else            
           cb2_pulse_o <= 1'b1;
      end

      // Interrupt logic
      irq_flags <= irq_flags | irq_events;

      // Writes --
      if(wen && falling) begin
         // last_data <= data_in;
         if(addr == 4'h0) begin // ORB
            prb <= data_in;
            if(!pcr[5]) irq_flags[3] <= 1'b0;
            irq_flags[4] <= 1'b0;
         end
  
         if(addr == 4'h1) begin // ORA
            pra <= data_in;
            if(!pcr[1]) irq_flags[0] <= 1'b0;
            irq_flags[1] <= 1'b0;
	 end
                    
         if(addr == 4'h2) // DDRB
            ddrb <= data_in;
                
         if(addr == 4'h3) // DDRA
           ddra <= data_in;
                    
         if(addr == 4'h4) // TA LO counter (write=latch)
            timer_a_latch[7:0] <= data_in;
                    
         if(addr == 4'h5) begin // TA HI counter
            timer_a_latch[15:8] <= data_in;
            irq_flags[6] <= 1'b0;
         end
       
         if(addr == 4'h6) // TA LO latch
           timer_a_latch[7:0] <= data_in;
                    
         if(addr == 4'h7) begin // TA HI latch
            timer_a_latch[15:8] <= data_in;
            irq_flags[6] <= 1'b0;
         end
         
         if(addr == 4'h8) // TB LO latch
           timer_b_latch[7:0] <= data_in;
                    
         if(addr == 4'h9) // TB HI counter
           irq_flags[5] <= 1'b0;
                
         if(addr == 4'hA)  // Serial port
            irq_flags[2] <= 1'b0;
                    
         if(addr == 4'hB) // ACR (Auxiliary Control Register)
           acr <= data_in;
                    
         if(addr == 4'hC) // PCR (Peripheral Control Register)
           pcr <= data_in;
         
         if(addr == 4'hD) // IFR
           irq_flags <= irq_flags & ~data_in[6:0];
                    
         if(addr == 4'hE) begin // IER
            if(data_in[7]) // set
              irq_mask <= irq_mask | data_in[6:0];
            else // clear
              irq_mask <= irq_mask & ~data_in[6:0];
         end
                
         if(addr == 4'hF) // ORA no handshake
            pra <= data_in;
      end // if (wen && falling)

      // Reads - Output only --
      data_out <= 8'h00;
      if(addr == 4'h0) begin // ORB
         // Port B reads its own output register for pins set to output.
         data_out <= (prb & ddrb) | (irb & ~ddrb);
	 if(acr[7]) data_out[7] <= timer_a_out;
      end
      if(addr == 4'h1) // ORA
        data_out <= ira;
      if(addr == 4'h2) // DDRB
        data_out <= ddrb;
      if(addr == 4'h3) // DDRA
        data_out <= ddra;
      if(addr == 4'h4) // TA LO counter
        data_out <= timer_a_count[7:0];
      if(addr == 4'h5) // TA HI counter
        data_out <= timer_a_count[15:8];
      if(addr == 4'h6) // TA LO latch
        data_out <= timer_a_latch[7:0];
      if(addr == 4'h7) // TA HI latch
        data_out <= timer_a_latch[15:8];
      if(addr == 4'h8) // TA LO counter
        data_out <= timer_b_count[7:0];
      if(addr == 4'h9) // TA HI counter
        data_out <= timer_b_count[15:8];
      if(addr == 4'hA) // SR
        data_out  <= shift_reg;
      if(addr == 4'hB) // ACR
        data_out  <= acr;
      if(addr == 4'hC) // PCR
        data_out  <= pcr;
      if(addr == 4'hD) // IFR
        data_out  <= { irq_out, irq_flags };
      if(addr == 4'hE) // IER
        data_out  <= { 1'b1, irq_mask };
      if(addr == 4'hF) // ORA
        data_out  <= ira;

      // Read actions --
      if(ren && falling) begin
         if(addr == 4'h0) begin // ORB
            if(!pcr[5]) irq_flags[3] <= 1'b0;
            irq_flags[4] <= 1'b0;
         end
                                    
         if(addr == 4'h1) begin // ORA
            if(!pcr[1]) irq_flags[0] <= 1'b0;
            irq_flags[1] <= 1'b0;
         end
        
         if(addr == 4'h4) // TA LO counter
           irq_flags[6] <= 1'b0;
                    
         if(addr == 4'h8) // TB LO counter
           irq_flags[5] <= 1'b0;
                    
         if(addr == 4'hA) // SR
           irq_flags[2] <= 1'b0;
      end
   end
end
   
// -- PIO Out select --
assign port_a_o      = pra;
assign port_b_o[6:0] = prb[6:0];    
assign port_b_o[7]   = acr[7]?timer_a_out:prb[7];
   
assign port_a_t      = ddra;
assign port_b_t[6:0] = ddrb[6:0];
assign port_b_t[7]   = ddrb[7] | acr[7];
    
// -- Timer A
reg timer_a_reload;
reg timer_a_toggle;
reg timer_a_may_interrupt;

always @(posedge clock) begin
   if(falling) begin
      // always count, or load
                        
      if(timer_a_reload) begin
         timer_a_count  <= timer_a_latch;
         if(write_t1c_l)
           timer_a_count[7:0] <= data_in;

         timer_a_reload <= 1'b0;
         timer_a_may_interrupt <= timer_a_may_interrupt & acr[6];
      end else begin
        if(timer_a_count == 16'h0000)
          // generate an event if we were triggered
          timer_a_reload <= 1'b1;
         // Timer coutinues to count in both free run and one shot.                        
         timer_a_count <= timer_a_count - 16'h0001;
      end
   end
                
   if(rising) begin
      if(irq_events[6] && acr[7]) 
        timer_a_toggle <= !timer_a_toggle;
   end

   if(write_t1c_h) begin
      timer_a_may_interrupt <= 1'b1;
      timer_a_toggle <= !acr[7];
      timer_a_count  <= { data_in, timer_a_latch[7:0] };
      timer_a_reload <= 1'b0;
   end

   if(reset) begin
      timer_a_may_interrupt <= 1'b0;
      timer_a_toggle <= 1'b1;
      timer_a_count  <= latch_reset_pattern;
      timer_a_reload <= 1'b0;
   end
end

assign timer_a_out = timer_a_toggle;
assign irq_events[6] = rising && timer_a_reload && timer_a_may_interrupt;
         
reg timer_b_reload_lo;
reg timer_b_oneshot_trig;
reg timer_b_timeout;
reg pb6_c, pb6_d;

// TODO: check if timer_b_decrement should be combinatorial
// reg timer_b_decrement;  
wire	timer_b_decrement = !acr[5] || (pb6_d && !pb6_c);
   
always @(posedge clock) begin
//   timer_b_decrement <= 1'b0;

   if(rising) begin
      pb6_c <= port_b_i[6];
      pb6_d <= pb6_c;
   end
                                
   if(falling) begin
      timer_b_timeout <= 1'b0;
      timer_b_tick  <= 1'b0;

//      if(acr[5]) begin
//         if (pb6_d && !pb6_c)
//           timer_b_decrement <= 1'b1;
//      end else // one shot or used for shift register
//        timer_b_decrement <= 1'b1;
                        
      if(timer_b_decrement) begin
         if(timer_b_count == 16'h0000) begin
            if(timer_b_oneshot_trig) 
              timer_b_oneshot_trig <= 1'b0;
            timer_b_timeout <= 1'b1;
         end
         if(timer_b_count[7:0] == 8'h00) begin
            if((acr[4:2] == 3'b001) ||
	       (acr[4:2] == 3'b101) ||
	       (acr[4:2] == 3'b100))
	      timer_b_reload_lo <= 1'b1;
              timer_b_tick <= 1'b1;
	 end
         timer_b_count <= timer_b_count - 16'h0001;
      end
      if(timer_b_reload_lo) begin
         timer_b_count[7:0] <= timer_b_latch[7:0];
         timer_b_reload_lo <= 1'b0;
      end
   end

   if(write_t2c_h) begin
      timer_b_count <= { data_in, timer_b_latch[7:0] };
      timer_b_oneshot_trig <= 1'b1;
   end

   if(reset) begin
      timer_b_count        <= latch_reset_pattern;
      timer_b_reload_lo    <= 1'b0;
      timer_b_oneshot_trig <= 1'b0;                    
   end
end
   
assign irq_events[5] = rising && timer_b_timeout;
   
reg trigger_serial;
reg shift_clock_d;
reg shift_clock;
reg shift_tick_r;
reg shift_tick_f;
reg shift_timer_tick;
reg cb2_c2 = 1'b0;
reg [7:0] bit_cnt;  // TODO: check bit order

wire shift_pulse =
     // Mode 0 still loads the shift register to external pulse (MMBEEB SD-Card interface uses this)
     (!shift_active)?(
        (acr[4:2]==3'b000)?(shift_clock && !shift_clock_d):
        1'b0):     
     (acr[3:2]==2'b10)?1'b1:
     ((acr[3:2]==2'b00)||(acr[3:2]==2'b01))?shift_timer_tick:
     (shift_clock & !shift_clock_d);

always @(posedge clock) begin
   cb2_c2  <= cb2_i;

   if(rising) begin
      if(!shift_active) begin
         if(acr[4:2] == 3'b000)
           shift_clock <= cb1_i;
         else
           shift_clock <= 1'b1;
      end else if(acr[3:2] == 2'b11)
        shift_clock <= cb1_i;
      else if(shift_pulse)
        shift_clock <= !shift_clock;

      shift_clock_d <= shift_clock;
   end

   if(falling)
      shift_timer_tick <= timer_b_tick;

   if(reset) begin
      shift_clock <= 1'b1;
      shift_clock_d <= 1'b1;
   end
end

assign cb1_t_int = (acr[3:2]==2'b11)?1'b0:serport_en;
assign cb1_o_int = shift_clock_d;
assign ser_cb2_o = shift_reg[7];

assign serport_en = acr[4] || acr[3] || acr[2];
assign trigger_serial = (ren || wen) && addr == 4'hA;   
assign shift_tick_r = !shift_clock_d &&  shift_clock;
assign shift_tick_f =  shift_clock_d && !shift_clock;

always @(posedge clock) begin
   if(reset)
      shift_reg <= 8'hFF;
   else if(falling) begin
      if(wen && addr == 4'hA)
        shift_reg <= data_in;
      else if( acr[4] && shift_tick_f) //  output
        shift_reg <= { shift_reg[6:0], shift_reg[7] };
      else if(!acr[4] && shift_tick_r) // input
        shift_reg <= { shift_reg[6:0], cb2_c2 };
   end
end

// tell people that we're ready!
assign irq_events[2] = shift_tick_r && !shift_active && rising && serport_en;

always @(posedge clock) begin
   if(falling) begin
      if(!shift_active && acr[4:2] != 3'b000) begin
         if(trigger_serial) begin
            bit_cnt      <= 8'd7;
            shift_active <= 1'b1;
         end
      end  else begin // we're active
         if(acr[3:2] == 2'b00)
           shift_active <= acr[4]; // when 1'b1 we're active, but for mode 000 we go inactive.
         else if(shift_pulse && shift_clock) begin
            if(bit_cnt == 8'd0)
              shift_active <= 1'b0;
            else
              bit_cnt <= bit_cnt - 8'd1;
         end
      end                            
   end
   if(reset) begin
      shift_active <= 1'b0;
      bit_cnt      <= 8'd0;
   end
end

endmodule
