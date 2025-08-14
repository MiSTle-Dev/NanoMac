/*
  nanomac_tb.cpp 

  NanoMac verilator environment.
*/
  
#ifdef VIDEO
#include <SDL.h>
#include <SDL_image.h>
#endif
 
#include "Vnanomac_tb.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static Vnanomac_tb *tb;
static VerilatedFstC *trace;
static double simulation_time;

extern void sd_handle(float ms, Vnanomac_tb *tb);

#define ROM "plusrom.bin"

#define RAM_SIZE 1    // 0=128k, 1=512k, 2=1MB, 3=4MB

#define TICKLEN   (0.5/16000000)

// #define DEBUG_MEM

// times with 128k ram, 512k delays everything by 2.7 seconds
// #define TRACESTART .8
// #define TRACESTART 1.9   // kbd model cmd and first iwm access
// #define TRACESTART 2.2   // checkerboard, kbd  inquiry cmd, first SCSI
// #define TRACESTART 2.8   // tachometer calibration (until ~ 2.97)
// #define TRACESTART 3.9   // -"- (until ~ 2.97)
// #define TRACESTART 4.1   // floppy boot start
// #define TRACESTART 5.1   // Sony write called
// #define TRACESTART 20.0   // 128k / system 3.0 desktop reached

// #define TRACESTART 29.3
// #define TRACESTART 50
#define TRACESTART 33.2

#ifdef TRACESTART
#define TRACEEND     (TRACESTART + 0.5)
#endif

// floppy disk lba to side/track/sector translation table
int fdc_map[2][1600][3];

char *sector_string(int drive, uint32_t lba) {
  static char str[32];

  if(drive < 2) {  
    if(lba >= 1600)
      sprintf(str, "<out of range %u>", lba);
    else
      sprintf(str, "CHS %d/%d/%d",
	      fdc_map[1][lba][1],fdc_map[1][lba][0],fdc_map[1][lba][2]);
    
    return str;
  }

  strcpy(str, "");
  return str;
}

/* =============================== video =================================== */

#ifdef VIDEO
FILE *ad = NULL;

#define MAX_H_RES   2048
#define MAX_V_RES   1024

SDL_Window*   sdl_window   = NULL;
SDL_Renderer* sdl_renderer = NULL;
SDL_Texture*  sdl_texture  = NULL;
int sdl_cancelled = 0;

typedef struct Pixel {  // for SDL texture
    uint8_t a;  // transparency
    uint8_t b;  // blue
    uint8_t g;  // green
    uint8_t r;  // red
} Pixel;

#define SCALE 1
Pixel screenbuffer[MAX_H_RES*MAX_V_RES];

/*
  Mac video = 512x342, physical 704x370€60Hz -> 15.664 MHz pixel clock 
 */

void init_video(void) {
  if (SDL_Init(SDL_INIT_VIDEO) < 0) {
    printf("SDL init failed.\n");
    return;
  }

  sdl_window = SDL_CreateWindow("NanoMac", SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED, SCALE*704, SCALE*370, SDL_WINDOW_RESIZABLE | SDL_WINDOW_SHOWN);
  if (!sdl_window) {
    printf("Window creation failed: %s\n", SDL_GetError());
    return;
  }
  
  sdl_renderer = SDL_CreateRenderer(sdl_window, -1,
            SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
  if (!sdl_renderer) {
    printf("Renderer creation failed: %s\n", SDL_GetError());
    return;
  }
}

// https://stackoverflow.com/questions/34255820/save-sdl-texture-to-file
void save_texture(SDL_Renderer *ren, SDL_Texture *tex, const char *filename) {
    SDL_Texture *ren_tex = NULL;
    SDL_Surface *surf = NULL;
    int w, h;
    int format = SDL_PIXELFORMAT_RGBA32;;
    void *pixels = NULL;

    /* Get information about texture we want to save */
    int st = SDL_QueryTexture(tex, NULL, NULL, &w, &h);
    if (st != 0) { SDL_Log("Failed querying texture: %s\n", SDL_GetError()); goto cleanup; }

    // adjust aspect ratio
    while(w > 2*h) w/=2;
    
    ren_tex = SDL_CreateTexture(ren, format, SDL_TEXTUREACCESS_TARGET, w, h);
    if (!ren_tex) { SDL_Log("Failed creating render texture: %s\n", SDL_GetError()); goto cleanup; }

    /* Initialize our canvas, then copy texture to a target whose pixel data we can access */
    st = SDL_SetRenderTarget(ren, ren_tex);
    if (st != 0) { SDL_Log("Failed setting render target: %s\n", SDL_GetError()); goto cleanup; }

    SDL_SetRenderDrawColor(ren, 0x00, 0x00, 0x00, 0x00);
    SDL_RenderClear(ren);

    st = SDL_RenderCopy(ren, tex, NULL, NULL);
    if (st != 0) { SDL_Log("Failed copying texture data: %s\n", SDL_GetError()); goto cleanup; }

    /* Create buffer to hold texture data and load it */
    pixels = malloc(w * h * SDL_BYTESPERPIXEL(format));
    if (!pixels) { SDL_Log("Failed allocating memory\n"); goto cleanup; }

    st = SDL_RenderReadPixels(ren, NULL, format, pixels, w * SDL_BYTESPERPIXEL(format));
    if (st != 0) { SDL_Log("Failed reading pixel data: %s\n", SDL_GetError()); goto cleanup; }

    /* Copy pixel data over to surface */
    surf = SDL_CreateRGBSurfaceWithFormatFrom(pixels, w, h, SDL_BITSPERPIXEL(format), w * SDL_BYTESPERPIXEL(format), format);
    if (!surf) { SDL_Log("Failed creating new surface: %s\n", SDL_GetError()); goto cleanup; }

    /* Save result to an image */
    st = IMG_SavePNG(surf, filename);
    if (st != 0) { SDL_Log("Failed saving image: %s\n", SDL_GetError()); goto cleanup; }
    
    // SDL_Log("Saved texture as PNG to \"%s\" sized %dx%d\n", filename, w, h);

cleanup:
    SDL_FreeSurface(surf);
    free(pixels);
    SDL_DestroyTexture(ren_tex);
}

void capture_video(void) {
  static int last_hs_n = -1;
  static int last_vs_n = -1;
  static int sx = 0;
  static int sy = 0;
  static int frame = 0;
  static int frame_line_len = 0;
  
  // store pixel
  if(sx < MAX_H_RES && sy < MAX_V_RES) {  
    Pixel* p = &screenbuffer[sy*MAX_H_RES + sx];
    p->a = 0xFF;  // transparency
    p->r = (!tb->hs_n || tb->pix)?255:0;
    p->g = (!tb->vs_n || tb->pix)?255:0;
    p->b = tb->pix?255:0;
  }
  sx++;
    
  if(tb->hs_n != last_hs_n) {
    last_hs_n = tb->hs_n;

    // trigger on rising hs edge
    if(tb->hs_n) {
      // write audio
      int16_t audio = tb->audio << 5;
      if(ad) fwrite(&audio, 1, 2, ad);
      
      // no line in this frame detected, yet
      if(frame_line_len >= 0) {
	if(frame_line_len == 0)
	  frame_line_len = sx;
	else {
	  if(frame_line_len != sx) {
	    printf("frame line length unexpectedly changed from %d to %d\n", frame_line_len, sx);
	    frame_line_len = -1;	  
	  }
	}
      }
      
      sx = 0;
      sy++;
    }    
  }

  if(tb->vs_n != last_vs_n) {
    last_vs_n = tb->vs_n;

    // trigger on rising vs edge
    if(tb->vs_n) {
      // draw frame if valid
      if(frame_line_len > 0) {
	
	// check if current texture matches the frame size
	if(sdl_texture) {
	  int w=-1, h=-1;
	  SDL_QueryTexture(sdl_texture, NULL, NULL, &w, &h);
	  if(w != frame_line_len || h != sy) {
	    SDL_DestroyTexture(sdl_texture);
	    sdl_texture = NULL;
	  }
	}
	  
	if(!sdl_texture) {
	  sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
					  SDL_TEXTUREACCESS_TARGET, frame_line_len, sy);
	  if (!sdl_texture) {
	    printf("Texture creation failed: %s\n", SDL_GetError());
	    sdl_cancelled = 1;
	  }
	}
	
	if(sdl_texture) {	
	  SDL_UpdateTexture(sdl_texture, NULL, screenbuffer, MAX_H_RES*sizeof(Pixel));
	  
	  SDL_RenderClear(sdl_renderer);
	  SDL_RenderCopy(sdl_renderer, sdl_texture, NULL, NULL);
	  SDL_RenderPresent(sdl_renderer);

	  char name[32];
	  sprintf(name, "screenshots/frame%04d.png", frame);
	  save_texture(sdl_renderer, sdl_texture, name);
	}
      }
	
      // process SDL events
      SDL_Event event;
      while( SDL_PollEvent( &event ) ){
	if(event.type == SDL_QUIT)
	  sdl_cancelled = 1;
	
	if(event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE)
	    sdl_cancelled = 1;
      }
      
#ifndef UART_ONLY
      printf("%.3fms frame %d is %dx%d\n", simulation_time*1000, frame, frame_line_len, sy);
#endif

      frame++;
      frame_line_len = 0;

      // whatever has been drawn into the current line is actually content for line 0
      memcpy(screenbuffer, screenbuffer+sy*MAX_H_RES, MAX_H_RES*sizeof(Pixel));      
      sy = 0;
    }
  }
}
#endif

void hexdump(void *data, int size) {
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

void hexdiff(void *data, void *cmp, int size) {
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
      	printf("\033[1;33m%02x\033[0m ", 0xff&ptr[i]);
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

static uint64_t GetTickCountMs() {
  struct timespec ts;
  
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)(ts.tv_nsec / 1000000) + ((uint64_t)ts.tv_sec * 1000ull);
}

#define SWAP16(a)  (((a & 0x00ff)<<8)|((a & 0xff00)>>8))
unsigned short rom[128*1024];  // 128k

void load_rom(void) {
  printf("Loading rom\n");
  FILE *fd = fopen(ROM, "rb");
  if(!fd) { perror("load rom"); exit(-1); }
  
  int len = fread(rom, 1024, 128, fd);
  if(len != 128) { printf("read failed\n"); exit(-1); }
  fclose(fd);

}

// "normal" ram, basically sram like
unsigned short ram[4*512*1024];  // 4 Megabytes

// the sdram
uint32_t sdram[2*1024*1024];  // 2M 32 bit words

// proceed simulation by one tick
void tick(int c) {
  static uint64_t ticks = 0;
  static int uart_state = -1;

  tb->eval();

  tb->clk = c;

  static  int leds = 0;
  if(leds != tb->leds) {
    printf("%.3fms LEDs ", simulation_time*1000);
    for(int i=0;i<5;i++) printf("%c", (tb->leds&(0x10>>i))?'*':'-');
    printf("\n");

    leds = tb->leds;
  }
  
  if(c /* && !tb->reset */ ) {
    // leave reset after 2 ms of simulation time
    if ( tb->reset && simulation_time > 0.002) {
      printf("%.3fms Out of reset\n", simulation_time*1000);
      tb->reset = 0;
    }
    
    if( uart_state == -1) {
      if(simulation_time > .05) {
	printf("%.3fms UART start\n", simulation_time*1000);
	uart_state = 0;
      }
    } else if(uart_state != -2) {
      char *data = (char*)"Hello World";
      int bit = uart_state / (16000000/9600);   // bit rate = 9k6

      int stop_bits = 2;
      int byte = bit / (9+stop_bits);         //
      int bit_in_byte = bit % (9+stop_bits);

      if(bit_in_byte == 0)
	tb->uart_rxd = 0;                                  // start bit
      else if(bit_in_byte <= 8)
	tb->uart_rxd = (data[byte] & (1<<(bit_in_byte-1)))?1:0;    // data bit
      else
	tb->uart_rxd = 1;                                  // stop bit(s)

      uart_state++;

      if((byte == strlen(data)-1) && (bit_in_byte > 8))
	uart_state = -2;
    }
      
    // send a keycode
    if( !tb->kbd_strobe && simulation_time > 2.3) {
      printf("%.3fms KBD send code #1\n", simulation_time*1000);
      tb->kbd_strobe = !tb->kbd_strobe;
      tb->kbd_data = 0x01;   // should be 'a'      
    }

    // process sd card signals
    sd_handle(simulation_time*1000, tb);
    
    // ------------------------------------ simulate sdram -------------------------------------
    int sdram_has_returned_data = 0;
    if(!tb->sd_cs) {
      static int addrL, baL;
      
      // RAS phase
      if(!tb->sd_ras && tb->sd_cas && tb->sd_we) {
#ifdef DEBUG_MEM
	printf("%.3fms SDRAM ACTIVE %06x %d\n", simulation_time*1000, tb->sd_addr, tb->sd_ba);
#endif
	baL = tb->sd_ba;      // 2 bits
	addrL = tb->sd_addr;  // 11 bits
      }

      // CAS read/write
      if(tb->sd_ras && !tb->sd_cas) {
	// calculate full address, sd_addr now has the lowest 8 bits
	int addr = (baL << (8+11)) + (addrL << 8) + (tb->sd_addr & 0xff);
	
	if(tb->sd_we) {	  
	  sdram_has_returned_data = 1;
	  tb->sd_data_in = sdram[addr];
#ifdef DEBUG_MEM
	  printf("%.3fms SDRAM READ %06x -> %08x = %04x (%08x)\n", simulation_time*1000, tb->sd_addr, addr<<2, tb->sd_data_in, sdram[addr]);
#endif
	} else {
#ifdef DEBUG_MEM
	  printf("%.3fms SDRAM WRITE %06x -> %08x = %04x/%x\n", simulation_time*1000, tb->sd_addr, addr<<2, tb->sd_data_out, tb->sd_dqm);
#endif
	  // which bytes are being being written depends on the dqm bits
	  if(!(tb->sd_dqm & 1)) sdram[addr] = (sdram[addr] & 0xffffff00)|(tb->sd_data_out & 0x000000ff);
	  if(!(tb->sd_dqm & 2)) sdram[addr] = (sdram[addr] & 0xffff00ff)|(tb->sd_data_out & 0x0000ff00);
	  if(!(tb->sd_dqm & 4)) sdram[addr] = (sdram[addr] & 0xff00ffff)|(tb->sd_data_out & 0x00ff0000);
	  if(!(tb->sd_dqm & 8)) sdram[addr] = (sdram[addr] & 0x00ffffff)|(tb->sd_data_out & 0xff000000);	  
	}
      }
    }

    if(tb->phase == 6) {
      // --------------------- ROM --------------------    
      // check for start of rom access
      if(!tb->_romOE)
	// ALWAYS read rom- That way we don't have to wait for /AS
	tb->romData = SWAP16(rom[tb->romAddr]);

      // skip rom test
      if((simulation_time>1000000) && !tb->_romOE && ((tb->romAddr<<1)==0x18f44))
	printf("%.3fms Sony Write trigger <------------------------- \n", simulation_time*1000);
    }
      
    // only run sram cycle if ram was already selected in phase 2
    // /AS should always be active from phased 2 to 6	
    static int ram_cycle_selected;
    if(tb->phase == 2)
      ram_cycle_selected = tb->sdram_oe || tb->sdram_we;
    
    if(tb->phase == 6 && ram_cycle_selected) {
      // --------------------- RAM --------------------
      // Simulate a simple sram like memory, bypassing/ignoring the sdram controller completely
      // This may be used against the sdram controller to verify its correct operation.
      // Simulate memory working in state 6, so data is ready to be latched in cycle 7
      if(tb->sdram_we) {
#ifdef DEBUG_MEM
	printf("%.3fms RAM WR %08x/%d = %04x\n", simulation_time*1000, tb->ram_addr<<1, tb->sdram_ds, tb->sdram_din);
#endif
	
	// honour byte select
	unsigned char *ptr = (unsigned char*)&(ram[tb->ram_addr]);
	if(tb->sdram_ds & 2) ptr[0] = (tb->sdram_din >> 8) & 0xff;
	if(tb->sdram_ds & 1) ptr[1] = (tb->sdram_din) & 0xff;

	// check if sdram actually contains the same data. This should
	// be the case since the sdram runs a little earlier than the
	// simple sram like variant. In general, the SDRAM should have
	// done the same thing already
	uint16_t sdram_data = (tb->ram_addr & 1)?(sdram[tb->ram_addr>>1]&0xffff):
	  ((sdram[tb->ram_addr>>1]>>16)&0xffff);

	if(ram[tb->ram_addr] != SWAP16(sdram_data))
	  printf("%.3fms RAM write mismatch: @%08x: %04x != %04x\n", simulation_time*1000, tb->ram_addr<<1, ram[tb->ram_addr], SWAP16(sdram_data));
      }      
      
      if(tb->sdram_oe) {
	unsigned char *ptr = (unsigned char*)&(ram[tb->ram_addr]);
	tb->sdram_do = ptr[0] * 256 + ptr[1];

#ifdef DEBUG_MEM
	printf("%.3fms RAM RD %08x = %04x\n", simulation_time*1000, tb->ram_addr<<1,tb->sdram_do );
#endif	
	// verify both ram implementations. These should always return the same data
	if(tb->sdram_do != ((tb->sd_data_in>>((tb->ram_addr & 1)?0:16)) & 0xffff))	
	  printf("%.3fms RAM read mismatch @%08x: %04x != %04x\n", simulation_time*1000, tb->ram_addr<<1, tb->sdram_do, (tb->sd_data_in>>((tb->ram_addr & 1)?0:16)) & 0xffff);
      } else if(sdram_has_returned_data) {
	// It should never happen that the sdram has returned data but the sram is not	
	printf("%.3fms SDRAM has read, bit sram didn't!\n", simulation_time*1000);
      }
    }
  }
    
#ifdef VIDEO
  if(c) capture_video();
#endif

  if(simulation_time == 0)
    ticks = GetTickCountMs();
  
  // after one simulated millisecond calculate real time */
  if(simulation_time >= 0.001 && ticks) {
    ticks = GetTickCountMs() - ticks;
    printf("Speed factor = %lu\n", ticks);
    ticks = 0;
  }
  
  // trace after
#ifdef TRACESTART
  if(simulation_time > TRACESTART) trace->dump(1000000000000 * simulation_time);
#endif
  simulation_time += TICKLEN;
}

void fexit(void) {
  if(ad) {
    fclose(ad);
    ad = NULL;
  }
}

int main(int argc, char **argv) {
  // Initialize Verilators variables
  Verilated::commandArgs(argc, argv);
  // Verilated::debug(1);
  Verilated::traceEverOn(true);
  trace = new VerilatedFstC;
  trace->spTrace()->set_time_unit("1ns");
  trace->spTrace()->set_time_resolution("1ps");
  simulation_time = 0;

  atexit(fexit);
 
  // create fdc lba map
  int lba_ds = 0;
  int lba_ss = 0;
  for(int track=0;track<80;track++) {
    int spt;
    if(track >= 64) spt = 8;
    else if(track >= 48) spt = 9;
    else if(track >= 32) spt = 10;
    else if(track >= 16) spt = 11;
    else                 spt = 12;
    
    for(int side=0;side<2;side++) {
      for(int sector=0;sector<spt;sector++) {
	if(side == 0) {
	  fdc_map[0][lba_ss][0] = side;
	  fdc_map[0][lba_ss][1] = track;
	  fdc_map[0][lba_ss++][2] = sector;
	}
	
	fdc_map[1][lba_ds][0] = side;
	fdc_map[1][lba_ds][1] = track;
	fdc_map[1][lba_ds++][2] = sector;
      }
    }
  }
  
#ifdef VIDEO
  init_video();
  ad = fopen("audio.s16", "wb");
#endif

  load_rom();

  // Create an instance of our module under test
  tb = new Vnanomac_tb;
  tb->trace(trace, 99);
  trace->open("nanomac.fst");
  
  tb->reset = 1;
  tb->uart_rxd = 1;
  tb->ram_size = RAM_SIZE;
  tb->fastboot = 1;
  
  /* run for a while */
  while(
#ifdef TRACEEND
	simulation_time<TRACEEND &&
#endif
#ifdef VIDEO 
	!sdl_cancelled &&
#endif
	1) {
#ifdef TRACEEND
    // do some progress outout
    int percentage = 100 * simulation_time / TRACEEND;
    static int last_perc = -1;
    if(percentage != last_perc) {
#ifndef UART_ONLY
      printf("progress: %d%%\n", percentage);
#endif
      last_perc = percentage;
    }
#endif
    tick(1);
    tick(0);
  }
  
  printf("stopped after %.3fms\n", 1000*simulation_time);
  
  trace->close();

  //  hexdump(ram, 128*1024);
  fexit();
}
