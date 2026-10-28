// Firmware updates over BLE: the app streams a new image into the spare app slot, the racket verifies it
// and reboots into it. A new image that crashes before it has run for a few seconds is rolled back by the
// bootloader. Protocol: TB_OTA_* in protocol.h.
#pragma once
#include <NimBLEDevice.h>

// Adds the OTA characteristics to the racket's service (call before svc->start()).
void otaSetup(NimBLEService *svc);

// True while an update is being received; IMU streaming pauses so the image gets the full link.
bool otaActive();

// Call when a client disconnects: abandons an update that client was sending.
void otaHandleDisconnect(uint16_t connHandle);

// Call from loop(): reboots after a finished update and confirms a freshly updated image once it has
// run long enough.
void otaLoop();
