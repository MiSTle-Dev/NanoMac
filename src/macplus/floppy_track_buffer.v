/* 
  floppy_track_buffer.v
 
  Read/write floppy tracks from floppy disk images stored on
  sd card. This keeps a local buffer of a complete track of
  up to 12 sectors per side.
 */

module floppy_track_buffer 
   (
    input	      clk,
    input	      rst,

    // iwm/floppy info of currently addressed track
    input [1:0]	      eject,
    input             activity,	      
    input	      drive, // 0=int, 1=ext
    input	      side,
    input [6:0]	      track, // current track
    output [3:0]      spt,

    // floppy interface to access data in buffer
    output	      ready, // valid track is in buffer
    input [13:0]      addr, // byte requested
    output reg [7:0]  data, // data returned
    output	      dirty,
    
    // data written by IWM and decoded into sector format
    input [7:0]	      writeDataDecoded,
    input [8:0]	      writeAddr,
    input [3:0]	      writeSector,
    input	      writeStrobe,

    // a floppy disk image may at most be 819200 bytes or 1600 sectors big
    input [31:0]      sd_img_size,
    input [1:0]	      sd_img_mounted,
    output [1:0]      inserted,
    output [1:0]      sides,

    output reg [10:0] sd_lba,
    output reg [1:0]  sd_rd,
    output reg [1:0]  sd_wr,
    input	      sd_busy,
    input	      sd_done,
    input [8:0]	      sd_addr,
    input	      sd_data_en,
    input [7:0]	      sd_data_in,
    output reg [7:0]  sd_data_out
);

// Keep track of eject events, 
reg [1:0] ejected = 2'b00;   
   
reg [31:0] size [2] = {0,0};   
assign inserted = { !ejected[1] && size[1] != 32'd0, !ejected[0] && size[0] != 32'd0 };   

// Proper sides handling is actually not needed since the images contain the
// tracks for both sides subsequently and it doesn't make a difference if
// e.g. the 5th track of a single sided disk is read or the third track of
// the second side of a double sided disk. Both are at the same offset
// within the image file. We handle sides here, anyway, as it's just cleaner.
assign sides = { size[1] > 32'd409600, size[0] > 32'd409600};   

always @(posedge clk) begin
   if(sd_img_mounted[0]) begin
      size[0] <= sd_img_size;
      ejected[0] <= 1'b0;
   end
      
   if(sd_img_mounted[1])  begin
      size[1] <= sd_img_size;
      ejected[1] <= 1'b0;
   end

   if(eject[0]) ejected[0] <= 1'b1;
   if(eject[1]) ejected[1] <= 1'b1;
   
end   
   
// ---------------- calculate side/track into offset into floppy image ---------------

// The track to be used for Sd card IO depends on read or write. On read
// it's the newly requested track, on write it's the one in the buffer.
wire [6:0] iotrack;
   
// number of sectors on current track. This is exported to the floppy to generate the
// correct pattern of the "spinning" floppy. So this should actually always be the spt
// of the track in buffer. Actually all the parameters (side, track, ...) are only
// used when the track_buffer signals "ready" and this in turn only happens if the
// track in buffer matches the requested one.
assign spt =
     (iotrack[6:4] == 3'd0)?4'd12: // track  0 - 15
     (iotrack[6:4] == 3'd1)?4'd11: // track 16 - 31
     (iotrack[6:4] == 3'd2)?4'd10: // track 32 - 47
     (iotrack[6:4] == 3'd3)?4'd9:  // track 48 - 63
     4'd8;                         // track 64 - ...

// all possible tack*sector factors
wire [9:0] track_times_12 =      // x*12 = x*8 + x*4
    { iotrack, 3'b000 } +        // x<<3 +
    { 1'b0, iotrack, 2'b00 };    // x<<2 
   
wire [9:0] track_times_11 =      // x*11 = x*8 + x*2 + x*1
    { iotrack, 3'b000 } +        // x<<3 +
    { 2'b00, iotrack, 1'b0 } +   // x<<1 +
    { 3'b000, iotrack };         // x<<0 

wire [9:0] track_times_10 =      // x*10 = x*8 + x*2
    { iotrack, 3'b000 } +        // x<<3 +
    { 2'b00, iotrack, 1'b0 };    // x<<1

wire [9:0] track_times_9 =       // x*9 = x*8 + x*1
    { iotrack, 3'b000 } +        // x<<3 +
    { 3'b000, iotrack };         // x<<0

wire [9:0] track_times_8 =       // x*8
    { iotrack, 3'b000 };         // x<<3
   
// sector offset of current track is the sum of all sectors on all tracks before
wire [6:0] trackm1 = iotrack - 7'd1;
wire [9:0] soff =
      (iotrack == 0)?10'd0:                                               // track  0
      (trackm1[6:4] == 3'd0)?track_times_12:                              // track  1 - 16
      (trackm1[6:4] == 3'd1)?(track_times_11 + 10'd16):                   // track 17 - 32 
      (trackm1[6:4] == 3'd2)?(track_times_10 + 10'd32 + 10'd16):          // track 33 - 48 
      (trackm1[6:4] == 3'd3)?(track_times_9 + 10'd48 + 10'd32 + 10'd16):  // track 49 - 64 
      (track_times_8 + 10'd64 + 10'd48 + 10'd32 + 10'd16);                // track 65 -
   
// This encoder contains a buffer for one single track which it will refill
// from SD card whenever needed.
reg [7:0]  track_in_buffer;         // track currently stored in buffer (drive/side/track)
reg [7:0]  track_buffer [24*512];   // max 12 sectors per track and side
reg [23:0] track_buffer_dirty;      // sectors have been written
reg [4:0]  track_loader_sector;     // sector 0..23 within track currently being read
reg [7:0]  track_loader_state;
reg [7:0]  track_in_progress;
reg [3:0]  track_spt;   
reg	   track_force_write_back;  // disk activity has been stopped while buffer was dirty

// signal a dirty track buffer to e.g. light up a LED
assign dirty = track_buffer_dirty != 24'h000000;
   
wire [6:0] track_in_buffer_track = track_in_buffer[6:0];   // track no of track in buffer
wire	   track_in_buffer_drive = track_in_buffer[7];     // drive -"-
   
// iowriting indicates that the track in buffer is not the one requested/needed
// and sectors need to be flushed. In that case track information used as the basis
// for sd card IO is taken from the track in buffer and not the one being requested
wire iowriting = ((track_loader_state == 0) && !ready && track_buffer_dirty) || 
     (track_loader_state == 5) || (track_loader_state == 6);
assign iotrack = iowriting?track_in_buffer_track:track;

// determine which sector to write next
wire [4:0] track_sector_to_write =
	   track_buffer_dirty[0]?5'd0:
	   track_buffer_dirty[1]?5'd1:
	   track_buffer_dirty[2]?5'd2:
	   track_buffer_dirty[3]?5'd3:
	   track_buffer_dirty[4]?5'd4:
	   track_buffer_dirty[5]?5'd5:
	   track_buffer_dirty[6]?5'd6:	   
	   track_buffer_dirty[7]?5'd7:
	   track_buffer_dirty[8]?5'd8:
	   track_buffer_dirty[9]?5'd9:
	   track_buffer_dirty[10]?5'd10:
	   track_buffer_dirty[11]?5'd11:
	   track_buffer_dirty[12]?5'd12:
	   track_buffer_dirty[13]?5'd13:
	   track_buffer_dirty[14]?5'd14:
	   track_buffer_dirty[15]?5'd15:
	   track_buffer_dirty[16]?5'd16:
	   track_buffer_dirty[17]?5'd17:
	   track_buffer_dirty[18]?5'd18:	   
	   track_buffer_dirty[19]?5'd19:
	   track_buffer_dirty[20]?5'd20:
	   track_buffer_dirty[21]?5'd21:
	   track_buffer_dirty[22]?5'd22:
	   track_buffer_dirty[23]?5'd23:
	   5'd31;   

// One single track of up to 12 sectors is kept in local memory. The
// unique track is identified by drive (0/1), side (0/1) and track index (0..79)
wire [7:0] track_requested = ejected[drive]?8'hff:{drive, track};

// The track buffer signals "ready" whenever the track requested by the mac/iwm/floppy
// is actually the one that's currently stored in the buffer. Only then can the iwm
// read or write from and to the buffer 
assign ready = (track_in_buffer == track_requested) && !track_force_write_back;
   
// Read from track buffer. While ready return the data from the buffer to the iwm.
// Otherwise return data as requested by the sd card as a write may be in progress.
wire [14:0] rd_addr = {1'b0,addr} + (side?{spt, 9'd0}:14'd0);
   
always @(posedge clk) begin
  if(ready)  data <= track_buffer[rd_addr];
  else       sd_data_out <= track_buffer[{track_sector_to_write, sd_addr}];
end

// state machine to make sure the correct track is in buffer
always @(posedge clk) begin
   reg activityD;   
   reg writeStrobeD;   
   
   if(rst) begin
      track_in_buffer <= 8'hff;      
      track_loader_state <= 8'd0;
      sd_rd <= 2'b00;
      sd_wr <= 2'b00;
      track_force_write_back <= 1'b0;      
      track_buffer_dirty <= 24'h000000;      
   end else begin
      writeStrobeD <= writeStrobe;
      activityD <= activity;

      // once any activity has stopped, any pending dirty buffer
      // is written back to disk
      if(!activity && activityD && track_buffer_dirty)
	track_force_write_back <= 1'b1;      
      
      case(track_loader_state)
	// idle state
	0: if(!ready && !sd_busy && (size[drive] != 32'd0)) begin
	   // the wrong track is in buffer, there's a disk in the requested drive
	   // and the sd card is not busy -> load the right track, but flush any
	   // dirty sectors before
	   
	   // flush any dirty sectors before starting to read new
	   if(track_buffer_dirty) begin
	      // twice the sector offset for double sided disk, soff is derived from
	      // track_in_buffer during write as well

	      // soff and spt are currently derived from track_in_buffer/iotrack as
	      // the requested track/side/drive is _not_ the one to flush to

	      // TODO: check if spt still needs to be derived from iotrack
	      sd_lba <= (sides[track_in_buffer_drive]?{soff,1'b0}:{1'b0,soff}) + 
			{ 6'd0, track_sector_to_write };	       // write first dirty sector     

	      // request sd card write
	      sd_wr <= track_in_buffer_drive?2'b10:2'b01;
	      track_loader_state <= 8'd5;
	      
	   end else if(inserted[drive] && track_requested != 8'hff) begin
	      $display("floppy_track_buffer.v: track requested: %0d", track_requested);
	   
	      track_in_buffer <= 8'hff;      // mark buffer contents invalid

	      // latch current track information as it may change during sd card access
	      track_in_progress <= track_requested;	   
	      track_spt <= spt;	   	   

	      // request first sector from sd card
	      track_loader_sector <= 5'd0;      
	      sd_lba <= (sides[drive]?{soff,1'b0}:{1'b0,soff}); // twice the sector offset for double sided disk
	      sd_rd <= drive?2'b10:2'b01;

	      track_buffer_dirty <= 24'h000000;      
	      track_loader_state <= 8'd1;
	      track_force_write_back <= 1'b0;      
	   end
	end else if(ready) begin
	   // The track is valid and doesn't have to be reloaded. 
	   // Check if bytes are to be written by IWM

	   // TODO: Setting the dirty flag forces a writeback to sd card. The
	   // track codec can actually detect "write errors" which are basically
	   // malformed data being written to the IWM. In that case we may want
	   // to clear the dirty flag again, as we don't want the broken
	   // data to actually be written to sd card.	   

	   // act on falling edge of strobe when all signals had some time to settle
	   if( writeStrobe ^ writeStrobeD ) begin
	      logic [4:0] wr_sector = {1'b0,writeSector}+(side?{1'b0,spt}:5'd0);
	      track_buffer_dirty[wr_sector] <= 1'b1;	      
	      track_buffer[{wr_sector, writeAddr}] <= writeDataDecoded;
	   end
	end

	// waiting for sd card to become busy
	1: if(sd_busy) begin
	   sd_rd <= 2'b00;	   
	   track_loader_state <= 8'd2;
	end
	   
	// sd card has read sector and is now returning sector data
	2: begin
	   if(sd_data_en) begin
	      track_buffer[{track_loader_sector, sd_addr}] <= sd_data_in;

	      // stop reading after byte 511	   
	      if(sd_addr == 9'd511)
		track_loader_state <= 8'd3;
	   end
	end

	// wait while busy is still set
	3: begin
	   if(!sd_busy)
	     track_loader_state <= 8'd4;
	end

	// received one sector, request next one
	4: begin
	   // check if we have all sectors for this track
	   if(track_loader_sector >= (2*track_spt)-1) begin
	      // yes, we did, mark track buffer as valid again
	      track_in_buffer <= track_in_progress;	      

	      // return to idle state
	      track_loader_state <= 8'd0;
	   end else begin	   
	      // check if track has changed
	      if(track_in_progress != track_requested) begin
		 // Requested track has changed. Abort,
		 // leave buffer marked invalid and allow
		 // loader to start allover
		 track_loader_state <= 8'd0;		 
	      end else begin
		 // The same track is still being requested,
		 // continue loading it
		 track_loader_sector <= track_loader_sector + 5'd1;      
		 sd_lba <= sd_lba + 11'd1;	      
		 sd_rd <= track_in_progress[7]?2'b10:2'b01;

		 // continue loading next sector
		 track_loader_state <= 8'd1;
	      end
	   end
	end

	// waiting for sd card to become busy
	5: if(sd_busy) begin
	   sd_wr <= 2'b00;	   
	   track_loader_state <= 8'd6;
	end

	// write one sector, return data and wait until not busy, anymore
	6: if(!sd_busy) begin
	   // buffer for this sector not dirty, anymore
	   track_buffer_dirty[track_sector_to_write] <= 1'b0;
	   track_loader_state <= 8'd0;
	end 
	
      endcase      
   end
end   

endmodule
