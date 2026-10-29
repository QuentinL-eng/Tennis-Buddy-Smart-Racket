// Impact windows waiting to reach the phone (firmware 1.6, TB_STREAM_IMPACTS_ACKED).
//
// RAM: BL_SLOTS windows. The sampler fills one when a hit's window completes, the shot task adds its summary, the
// loop sends the summary and then the chunks, and frees the slot once the app acks it (or, for an app in plain
// impact mode, once the last chunk is out). Unacked windows are sent again after BL_RESEND_MS.
//
// Flash: when every slot is taken (the link is slow or the phone is gone), the oldest is written to a log of
// fixed BL_RECORD_SIZE records in the spare data partition, and read back once the link is free. Erasing stalls
// the CPU for tens of ms, so sectors are only erased while the racket is idle; writes go one page per step.
//
// No Arduino dependencies: the flash is reached through BacklogFlash, so tools/backlog_test/ runs it on a laptop.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "impact.h"
#include "protocol.h"

#define BL_SLOTS 6
#define BL_RESEND_MS 5000
#define BL_SECTOR 4096
#define BL_PAGE 256
#define BL_RECORD_SIZE (3 * BL_SECTOR)

struct BacklogFlash {
  uint32_t size;   // bytes in the partition; 0 = no flash backlog
  bool (*read)(uint32_t off, void *dst, uint32_t len);
  bool (*write)(uint32_t off, const void *src, uint32_t len);   // only clears bits; the range must be erased
  bool (*erase)(uint32_t off, uint32_t len);                     // whole sectors
};

enum : uint8_t { BL_FREE, BL_FILLING, BL_CAPTURED, BL_READY, BL_SENT };

struct BacklogSlot {
  volatile uint8_t state;
  bool summaryOk;      // the shot task produced a summary
  bool summarySent;
  bool backlog;        // sent late: spilled to flash, or captured while no phone was connected
  uint16_t boot;
  uint32_t order;      // capture order, oldest first
  uint32_t hitMs;      // millis() when captured (this boot only)
  uint64_t unixMs;     // wall-clock time of the hit, if known; else 0
  int32_t flashRec;    // flash record holding this window, or -1
  uint64_t pending;    // chunk bits still to send
  uint32_t sentAtMs;
  TBShotSummary summary;
  ImpactWindow win;
};

// Message the loop should send next (see backlogNext).
struct BacklogMsg {
  enum Kind : uint8_t { NONE, SUMMARY, CHUNK } kind;
  int slot;
  int chunk;
};

void backlogInit(uint16_t boot, const BacklogFlash *flash);
BacklogSlot &backlogSlot(int i);

// Sampler: a slot to capture the next window into (-1 if none is free), then hand it over when filled.
int backlogReserve();
void backlogCaptured(int slot, uint32_t nowMs, uint64_t unixMs, bool backlog);
void backlogRelease(int slot);   // a reserved slot that won't be used (e.g. capture turned off)
void backlogDropped();           // a window completed with no slot to put it in

// Shot task: the next captured window, then its result (ok = false: no summary, the app analyses the window).
int backlogNextCaptured();
void backlogAnalyzed(int slot, bool ok);

// Loop: what to send next. acked: the app speaks TB_STREAM_IMPACTS_ACKED. Call backlogSent after sending it.
BacklogMsg backlogNext(bool acked, uint32_t nowMs);
void backlogSent(const BacklogMsg &m, bool acked, uint32_t nowMs);

// The app's TB_CMD_WINDOW_ACK / TB_CMD_WINDOW_RESEND. Return false if no such window is held.
bool backlogAck(uint16_t boot, uint16_t seq);
bool backlogResend(uint16_t boot, uint16_t seq, const uint8_t *chunks, int n);

// Loop housekeeping, one small step per call: spill to flash when RAM is full, erase ahead while idle, load a
// flash record when the link is free. connected: an app in TB_STREAM_IMPACTS_ACKED is connected. Returns true
// if it touched the flash (so the caller can yield to the sampler).
bool backlogStep(bool connected, bool idle, uint32_t nowMs);

// Counters for the status line and tests.
struct BacklogStats {
  uint32_t captured, dropped, acked, resent, spilled, loaded, flashLost, flashPending, erasedAhead;
};
BacklogStats backlogStats();
