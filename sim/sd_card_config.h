#ifndef SD_CARD_CONFIG_H
#define SD_CARD_CONFIG_H

#define TICKLEN   (0.5/16000000)

#define TB_NAME   Vnanomac_tb

#include "Vnanomac_tb.h"

#ifdef SD_CARD_CPP
const char *file_image[8] = {
  "../disks/Disk605.dsk",    // internal floppy
  "../disks/speedometer.dsk",  // external floppy
  NULL, // "./boot_work.vhd",  // SCSI HDD #1
  NULL, NULL, NULL, NULL, NULL
};
#endif

#define MAX_DRIVES   4   // Internal/external floppy, SCSI 0/1

// enable to test direct mapping bypassing the companion if possible
#define ENABLE_DIRECT_MAP

// enable writing of modified data back into image ... potentially corrupting it
// #define WRITE_BACK

// enable this to simulate a FPGA Companion constantly writing and reading data,
// potentially colliding with the Core's own accesses
// #define FC_RW_STORM

// interface to sd card simulation
void sd_init(void);
void sd_handle(void);
void sd_get_sector(int drive, int lba, uint8_t *data);

void hexdump(void *data, int size);
void hexdiff(void *data1, void *data2, int size);

// clocks the SD card claims to be busy before read data is returned
#define READ_BUSY_COUNT 1000

#endif
