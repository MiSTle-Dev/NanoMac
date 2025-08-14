/*
  sd_card.cpp

  The simulation does not include the FPGA Companion. There's thus
  no instance that maps the different floppy/SCSI devices onto the
  SD card. The simulation thus includes the target device into the
  upper 8 bits of the LBA and this sd card simulation maps the
  request onto the four images files based on that.
*/

#include <stdio.h>
#include <ctype.h>
#include <cstdint>

#include "Vnanomac_tb.h"

const char *file_image[] = {
  "./NanoMacTracker.dsk", // internal floppy
  // "./FloppyWrite.dsk", // internal floppy
  // NULL, // "../disks/system30_minimal_work.dsk", // internal floppy
  NULL, // "../disks/HelloWorld.dsk",            // external floppy
  NULL, // "./boot_work.vhd",                  // SCSI HDD #1
  NULL
};
  
// #define WRITE_BACK

// disable colorization for easier handling in editors 
#if 1
#define RED      "\033[0;31m"
#define GREEN    "\033[0;32m"
#define YELLOW   "\033[1;33m"
#define END      "\033[0m"
#else
#define RED
#define GREEN
#define YELLOW
#define END
#endif


// <= 1000  ok
// >= 5000 early write error -36 at ~15000 msec with FloppyWrite.dsk test
// in between fails sometimes/later
#define READ_BUSY_COUNT 1000

extern char *sector_string(int drive, uint32_t lba);

static void hexdump(void *data, int size) {
  int i, b2c;
  int n=0;
  char *ptr = (char*)data;

  if(!size) return;

  while(size>0) {
    printf("%04x: ", n);

    b2c = (size>16)?16:size;
    for(i=0;i<b2c;i++)      printf("%02x ", 0xff&ptr[i]);
    printf("  ");
    for(i=0;i<(16-b2c);i++) printf("   ");
    for(i=0;i<b2c;i++)      printf("%c", isprint(ptr[i])?ptr[i]:'.');
    printf("\n");

    ptr  += b2c;
    size -= b2c;
    n    += b2c;
  }
}

static void hexdiff(void *data, void *cmp, int size) {
  int i, b2c;
  int n=0;
  char *ptr = (char*)data;
  char *cptr = (char*)cmp;

  if(!size) return;

  while(size>0) {
    printf("%04x: ", n);

    b2c = (size>16)?16:size;
    for(i=0;i<b2c;i++) {
      if(cptr[i] == ptr[i])      
	printf("%02x ", 0xff&ptr[i]);
      else
      	printf(YELLOW "%02x" END " ", 0xff&ptr[i]);
    }
      
    printf("  ");
    for(i=0;i<(16-b2c);i++) printf("   ");
    for(i=0;i<b2c;i++)      printf("%c", isprint(ptr[i])?ptr[i]:'.');
    printf("\n");

    ptr  += b2c;
    cptr  += b2c;
    size -= b2c;
    n    += b2c;
  }
}

// Calculate CRC7
// It's a 7 bit CRC with polynomial x^7 + x^3 + 1
// input:
//   crcIn - the CRC before (0 for first step)
//   data - byte for CRC calculation
// return: the new CRC7
uint8_t CRC7_one(uint8_t crcIn, uint8_t data) {
  const uint8_t g = 0x89;
  uint8_t i;

  crcIn ^= data;
  for (i = 0; i < 8; i++) {
    if (crcIn & 0x80) crcIn ^= g;
    crcIn <<= 1;
  }
  
  return crcIn;
}

// Calculate CRC16 CCITT
// It's a 16 bit CRC with polynomial x^16 + x^12 + x^5 + 1
// input:
//   crcIn - the CRC before (0 for rist step)
//   data - byte for CRC calculation
// return: the CRC16 value
uint16_t CRC16_one(uint16_t crcIn, uint8_t data) {
  crcIn  = (uint8_t)(crcIn >> 8)|(crcIn << 8);
  crcIn ^=  data;
  crcIn ^= (uint8_t)(crcIn & 0xff) >> 4;
  crcIn ^= (crcIn << 8) << 4;
  crcIn ^= ((crcIn & 0xff) << 4) << 1;
  
  return crcIn;
}

uint8_t getCRC(unsigned char cmd, unsigned long arg) {
  uint8_t CRC = CRC7_one(0, cmd);
  for (int i=0; i<4; i++) CRC = CRC7_one(CRC, ((unsigned char*)(&arg))[3-i]);
  return CRC;
}

uint8_t getCRC_bytes(unsigned char *data, int len) {
  uint8_t CRC = 0;
  while(len--) CRC = CRC7_one(CRC, *data++);
  return CRC;  
}

unsigned long long reply(unsigned char cmd, unsigned long arg) {
  unsigned long r = 0;
  r |= ((unsigned long long)cmd) << 40;
  r |= ((unsigned long long)arg) << 8;
  r |= getCRC(cmd, arg);
  r |= 1;
  return r;
}

static void update_crc(uint8_t *sector_data) {
  unsigned short crc[4] = { 0,0,0,0 };
  unsigned char dbits[4];
  for(int i=0;i<512;i++) {
    // calculate the crc for each data line seperately
    for(int c=0;c<4;c++) {
      if((i & 3) == 0) dbits[c] = 0;
      dbits[c] = (dbits[c] << 2) | ((sector_data[i]&(0x10<<c))?2:0) | ((sector_data[i]&(0x01<<c))?1:0);      
      if((i & 3) == 3) crc[c] = CRC16_one(crc[c], dbits[c]);
    }
  }
  
  //   printf("%.3fms SDC: CRC = %04x/%04x/%04x/%04x\n", ms, crc[0], crc[1], crc[2], crc[3]);
  
  // append crc's to sector_data
  for(int i=0;i<8;i++) sector_data[512+i] = 0;
  for(int i=0;i<16;i++) {
    int crc_nibble =
      ((crc[0] & (0x8000 >> i))?1:0) +
      ((crc[1] & (0x8000 >> i))?2:0) +
      ((crc[2] & (0x8000 >> i))?4:0) +
      ((crc[3] & (0x8000 >> i))?8:0);
    
    sector_data[512+i/2] |= (i&1)?(crc_nibble):(crc_nibble<<4);
  }
}

#define OCR  0xc0ff8000  // not busy, CCS=1(SDHC card), all voltage, not dual-voltage card
#define RCA  0x0013

// total cid respose is 136 bits / 17 bytes
unsigned char cid[17] = "\x3f" "\x02TMS" "A08G" "\x14\x39\x4a\x67" "\xc7\x00\xe4";

static FILE *fd[4] = { NULL, NULL, NULL, NULL };

void fdclose(void) {
  for(int i=0;i<4;i++) {  
    if(fd[i]) {
      printf("closing file image %d\n", i);
      fclose(fd[i]);
      fd[i] = NULL;
    }
  }
}

void sd_handle(float ms, Vnanomac_tb *tb)  {
  static int last_sdclk = -1;
  static unsigned long sector = 0xffffffff;
  static unsigned long long flen;
  static uint8_t sector_data[520];   // 512 bytes + four 16 bit crcs
  static long long cmd_in = -1;
  static long long cmd_out = -1;
  static unsigned char *cmd_ptr = 0;
  static int cmd_bits = 0;
  static unsigned char *dat_ptr = 0;
  static int dat_write = 0;
  static int dat_bits = 0;
  static unsigned long dat_arg;
  static int last_was_acmd = 0;
  static int write_busy = 0;
  static int read_busy = 0;
  
  // ----------------- simulate disk image insertion --------------------------
  static int insert_counter = 0;
  static int size;
  
  if(insert_counter < 4000) {
    int drive = insert_counter/1000;
    int cnt = insert_counter%1000;

    if(insert_counter == 10)
      atexit(fdclose);

    if(cnt == 300) {
      if(file_image[drive])
	fd[drive] = fopen(file_image[drive], "r+b");
      
      if(fd[drive]) {	
	fseek(fd[drive], 0, SEEK_END);
	size = ftello(fd[drive]);
	printf("%.3fms DRV %d mounting %s, size = %d\n", ms, drive, file_image[drive], size);
	fseek(fd[drive], 0, SEEK_SET);
	tb->image_size = size;
	tb->sddat_in = 15;	    
      }
    }
    
    if(fd[drive]) {
      if( cnt == 350 ) tb->image_mounted = 1<<drive;
      if( cnt == 351 ) tb->image_mounted = 0;
    }
    
    insert_counter++;
  }
      
  // ----------------- simulate sd card itself --------------------------
  if(tb->sdclk != last_sdclk) {
    // rising sd card clock edge
    if(tb->sdclk) {
      cmd_in = ((cmd_in << 1) | tb->sdcmd) & 0xffffffffffffll;

      if(dat_write) {
	// core writes to sd card
	if(dat_ptr && dat_bits) {
	  // 128*8 + 16 + 1 + 1
	  // printf("%.3fms SDC: WRITE %d %x\n", ms, dat_bits, tb->sddat);
	  if(dat_bits == 128*8 + 16 + 1 + 1 + 4) {
	    // wait for start bit(s)
	    if(tb->sddat != 0xf) {	    
	      // printf("%.3fms SDC: WRITE-4 START %x\n", ms, tb->sddat);	    
	      dat_bits--;
	    }
	  } else if(dat_bits > 1) {
	    if(dat_bits > 1+4) { 
	      int nibble = dat_bits&1;   // 1: high nibble, 0: low nibble
	      if(nibble) *dat_ptr   = (*dat_ptr & 0x0f) | (tb->sddat<<4);
	      else       *dat_ptr++ = (*dat_ptr & 0xf0) |  tb->sddat;
	    } else tb->sddat_in = 0;  // send 4 wack bits
	    
	    dat_bits--;
	  } else {
	    write_busy = 100;
	    // tb->sddat_in = 1;
	    
	    // save received crc
	    uint8_t crc_rx[8];
	    memcpy(crc_rx, sector_data+512, 8);    // copy supplied crc
	    update_crc(sector_data);               // recalc it

	    // and compare it
	    // printf("%.3fms SDC: WRITE DATA CRC is %s\n", ms, memcmp(sector_data+512, crc_rx, 8)?"INVALID!!!":"ok");
	    if(memcmp(sector_data+512, crc_rx, 8)) {
	      printf(RED "CRC received: "); hexdump(crc_rx, 8);
	      printf("CRC expected: "); hexdump(sector_data+512, 8);
	      printf("" END);
	    } else {
	      printf(GREEN "CRC ok: "); hexdump(crc_rx, 8);
	      printf("" END);
	    }

	    int i = dat_arg >> 24;
	    int drive = 0;
	    while(!(i&1)) { drive++; i>>=1; }
	    int lba = dat_arg & 0xffffff;

	    if(fd[drive]) {
	      uint8_t ref[512];

	      // read original sector for comparison
	      fseek(fd[drive], 512 * lba, SEEK_SET);
	      int items = fread(ref, 2, 256, fd[drive]);
	      if(items != 256) perror("fread()");

	      hexdiff(sector_data, ref, 512);
	    } else 	    
	      hexdump(sector_data, 520);

#ifdef WRITE_BACK
	    fseek(fd[drive], 512 * lba, SEEK_SET);
	    if(fwrite(sector_data, 2, 256, fd[drive]) != 256) {
	      printf("SDC WRITE ERROR\n");
	      exit(-1);
	    }	    
	    fflush(fd[drive]);
#endif
	    dat_bits--;
	  }
	}
	else if(write_busy) {
	  write_busy--;	  
	  tb->sddat_in = write_busy?0:15;
	}
      } else {      
	// core reads from sd card
	
	// sending 4 data bits
	if(dat_ptr && dat_bits) {
	  if(read_busy) {
	    tb->sddat_in = 15;	    
	    read_busy--;
	  } else {
	    if(dat_bits == 128*8 + 16 + 1 + 1) {
	      // card sends start bit
	      tb->sddat_in = 0;
	      // printf("%.3fms SDC: READ-4 START\n", ms);
	    } else if(dat_bits > 1) {
	      // if(dat_bits == 128*8 + 16 + 1) printf("%.3fms SDC: READ DATA START\n", ms);
	      int nibble = dat_bits&1;   // 1: high nibble, 0: low nibble
	      if(nibble) tb->sddat_in = (*dat_ptr >> 4)&15;
	      else       tb->sddat_in = *dat_ptr++ & 15;
	    } else
	      tb->sddat_in = 15;
	    
	    dat_bits--;
	  }
	}
      }
      
      if(cmd_ptr && cmd_bits) {
        int bit = 7-((cmd_bits-1) & 7);
        tb->sdcmd_in = (*cmd_ptr & (0x80>>bit))?1:0;
        if(bit == 7) cmd_ptr++;
        cmd_bits--;
      } else {      
        tb->sdcmd_in = (cmd_out & (1ll<<47))?1:0;
        cmd_out = (cmd_out << 1)|1;
      }
      
      // check if bit 47 is 0, 46 is 1 and 0 is 1
      if( !(cmd_in & (1ll<<47)) && (cmd_in & (1ll<<46)) && (cmd_in & (1ll<<0))) {
        unsigned char cmd  = (cmd_in >> 40) & 0x7f;
        unsigned long arg  = (cmd_in >>  8) & 0xffffffff;
        unsigned char crc7 = cmd_in & 0xfe;
	
        // r1 reply:
        // bit 7 - 0
        // bit 6 - parameter error
        // bit 5 - address error
        // bit 4 - erase sequence error
        // bit 3 - com crc error
        // bit 2 - illegal command
        // bit 1 - erase reset
        // bit 0 - in idle state

        if(crc7 == getCRC(cmd, arg)) {
          printf("%.3fms SDC: %sCMD %2d, ARG %08lx\n", ms, last_was_acmd?"A":"", cmd & 0x3f, arg);
          switch(cmd & 0x3f) {
          case 0:  // Go Idle State
            break;
          case 8:  // Send Interface Condition Command
            cmd_out = reply(8, arg);
            break;
          case 55: // Application Specific Command
            cmd_out = reply(55, 0);
            break;
          case 41: // Send Host Capacity Support
            cmd_out = reply(63, OCR);
            break;
          case 2:  // Send CID
            cid[16] = getCRC_bytes(cid, 16) | 1;  // Adjust CRC
            cmd_ptr = cid;
            cmd_bits = 136;
            break;
           case 3:  // Send Relative Address
            cmd_out = reply(3, (RCA<<16) | 0);  // status = 0
            break;
          case 7:  // select card
            cmd_out = reply(7, 0);    // may indicate busy          
            break;
          case 6:  // set bus width
            printf("%.3fms SDC: Set bus width to %ld\n", ms, arg);
            cmd_out = reply(6, 0);
            break;
          case 16: // set block len (should be 512)
            printf("%.3fms SDC: Set block len to %ld\n", ms, arg);
            cmd_out = reply(16, 0);    // ok
            break;
          case 17: { // read block
	    int i = arg >> 24;
	    int drive = 0;
	    while(!(i&1)) { drive++; i>>=1; }
	    int lba = arg & 0xffffff;

            printf("%.3fms SDC: Request #%d to read single block %d (%s)\n", ms,
		   drive, lba, sector_string(drive, lba));
            cmd_out = reply(17, 0);    // ok

	    if(fd[drive]) {
	      // load sector
	      fseek(fd[drive], 512 * lba, SEEK_SET);
	      int items = fread(sector_data, 2, 256, fd[drive]);
	      if(items != 256) perror("fread()");

	      hexdump(sector_data, 32);
	    } else {
	      printf("%.3fms SDC: No image loaded, sending empty data\n", ms);
	      memset(sector_data, 0, 512);
	    }

	    update_crc(sector_data);
            dat_ptr = sector_data;
            dat_write = 0;
            dat_bits = 128*8 + 16 + 1 + 1;

	    read_busy = READ_BUSY_COUNT;  // some delay to simulate card actually doing some read
	  } break;
            
          case 24: {  // write block
	    int i = arg >> 24;
	    int drive = 0;
	    while(!(i&1)) { drive++; i>>=1; }

            printf("%.3fms SDC: Request #%d to write single block %ld (%s)\n", ms,
		   drive, arg&0xffffff, sector_string(drive, arg&0xffffff));
            cmd_out = reply(24, 0);    // ok
	    
	    // prepare to receive data
	    dat_arg = arg;
            dat_ptr = sector_data;
            dat_write = 1;
            dat_bits = 128*8 + 16 + 1 + 1 + 4;

	  } break;

          default:
            printf("%.3fms SDC: unexpected command\n", ms);
          }

          last_was_acmd = (cmd & 0x3f) == 55;
          
          cmd_in = -1;
        } else
          printf("%.3fms SDC: CMD %02x, ARG %08lx, CRC7 %02x != %02x!!\n", ms, cmd, arg, crc7, getCRC(cmd, arg));         
      }      
    }      
    last_sdclk = tb->sdclk;     
  }
}      
