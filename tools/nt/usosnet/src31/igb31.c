/* Compile the unchanged own backend with the NT31 core's bounded PCI access. */
#include "usosnet31.h"
#define NdisReadPciSlotInformation Us31PciRead
#define NdisWritePciSlotInformation Us31PciWrite
#include "usosnet_igb.c"
