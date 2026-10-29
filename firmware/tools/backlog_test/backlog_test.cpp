// Host test for src/backlog.cpp, with a fake flash that, like the real one, can only clear bits between erases:
//
//   clang++ -std=c++17 -Iinclude -Isrc -o backlog_test tools/backlog_test/backlog_test.cpp src/backlog.cpp && ./backlog_test
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vector>

#include "backlog.h"

static std::vector<uint8_t> flash;
static int badWrites = 0, erases = 0, writes = 0;

static bool fRead(uint32_t off, void *dst, uint32_t len) {
  if (off + len > flash.size()) return false;
  memcpy(dst, &flash[off], len);
  return true;
}
static bool fWrite(uint32_t off, const void *src, uint32_t len) {
  if (off + len > flash.size()) return false;
  const uint8_t *p = (const uint8_t *)src;
  for (uint32_t k = 0; k < len; k++) {
    if ((flash[off + k] & p[k]) != p[k]) badWrites++;   // would need a 0 -> 1 change
    flash[off + k] &= p[k];
  }
  writes++;
  return true;
}
static bool fErase(uint32_t off, uint32_t len) {
  if (off % BL_SECTOR || len % BL_SECTOR || off + len > flash.size()) return false;
  memset(&flash[off], 0xFF, len);
  erases++;
  return true;
}

static int failures = 0;
#define CHECK(c)                                                  \
  do {                                                            \
    if (!(c)) {                                                   \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);         \
      failures++;                                                 \
    }                                                             \
  } while (0)

static uint32_t now = 1000;

// Captures one window with recognisable contents, as the sampler and shot task would.
static int capture(uint16_t seq, bool summary = true) {
  int s = backlogReserve();
  if (s < 0) return -1;
  BacklogSlot &b = backlogSlot(s);
  memset(&b.win, 0, sizeof(b.win));
  b.win.seq = seq;
  b.win.impact = TB_WINDOW_PRE;
  for (int k = 0; k < TB_WINDOW_SAMPLES; k++) b.win.s[k].gx = (int16_t)(seq * 1000 + k);
  backlogCaptured(s, now, 0, false);
  CHECK(backlogNextCaptured() == s);
  memset(&b.summary, 0, sizeof(b.summary));
  b.summary.swing_kmh = seq;
  backlogAnalyzed(s, summary);
  return s;
}

// Sends everything sendable; returns the number of chunks, and records the summaries' and windows' seqs.
static int drain(bool acked, std::vector<uint16_t> *summaries = nullptr, std::vector<uint16_t> *windows = nullptr) {
  int chunks = 0;
  for (int guard = 0; guard < 10000; guard++) {
    BacklogMsg m = backlogNext(acked, now);
    if (m.kind == BacklogMsg::NONE) break;
    BacklogSlot &b = backlogSlot(m.slot);
    if (m.kind == BacklogMsg::SUMMARY && summaries) summaries->push_back(b.win.seq);
    if (m.kind == BacklogMsg::CHUNK) {
      chunks++;
      // The chunk's samples are the window's: check nothing got scrambled through flash.
      CHECK(b.win.s[m.chunk * TB_SAMPLES_PER_PACKET].gx == (int16_t)(b.win.seq * 1000 + m.chunk * TB_SAMPLES_PER_PACKET));
      if (m.chunk == TB_WINDOW_CHUNKS - 1 && windows) windows->push_back(b.win.seq);
    }
    backlogSent(m, acked, now);
  }
  return chunks;
}

static void testAckedFlow() {
  backlogInit(7, nullptr);
  capture(1);
  capture(2);
  std::vector<uint16_t> sums, wins;
  CHECK(drain(true, &sums, &wins) == 2 * TB_WINDOW_CHUNKS);
  CHECK(sums.size() == 2 && sums[0] == 1 && sums[1] == 2);   // both summaries before any chunk
  CHECK(wins.size() == 2);
  CHECK(backlogAck(7, 1));
  CHECK(!backlogAck(6, 2));   // wrong boot
  // Window 2 was never acked: it goes again after the timeout, without its summary.
  now += BL_RESEND_MS + 1;
  sums.clear();
  CHECK(drain(true, &sums) == TB_WINDOW_CHUNKS);
  CHECK(sums.empty());
  CHECK(backlogAck(7, 2));
  CHECK(backlogNext(true, now).kind == BacklogMsg::NONE);
  // Resend of two chunks only.
  capture(3);
  drain(true);
  uint8_t missing[] = {4, 40};
  CHECK(backlogResend(7, 3, missing, 2));
  CHECK(drain(true) == 2);
  CHECK(backlogAck(7, 3));
}

static void testPlainImpactMode() {
  backlogInit(1, nullptr);
  capture(5);
  std::vector<uint16_t> sums;
  CHECK(drain(false, &sums) == TB_WINDOW_CHUNKS);
  CHECK(sums.empty());   // old apps don't know summaries
  CHECK(backlogReserve() >= 0);   // and the slot was freed without an ack
}

static void testRamFullWithoutFlashDropsNewest() {
  backlogInit(1, nullptr);
  for (int i = 0; i < BL_SLOTS; i++) CHECK(capture(i) >= 0);
  CHECK(backlogReserve() < 0);
}

static void stepUntilQuiet(bool connected, bool idle) {
  for (int k = 0; k < 2000 && backlogStep(connected, idle, now); k++) {
  }
}

static void testSpillAndReloadAcrossReboot() {
  flash.assign(8 * BL_RECORD_SIZE, 0xA5);   // never-erased partition: garbage
  BacklogFlash f = {(uint32_t)flash.size(), fRead, fWrite, fErase};
  backlogInit(10, &f);
  stepUntilQuiet(false, true);   // idle: erase ahead
  CHECK(backlogStats().erasedAhead >= 1);
  // Play with no phone: six hits fill RAM; idle time moves them to flash.
  for (int i = 0; i < BL_SLOTS; i++) CHECK(capture(100 + i) >= 0);
  stepUntilQuiet(false, true);
  CHECK(backlogStats().flashPending == BL_SLOTS);
  CHECK(backlogStats().spilled == BL_SLOTS);
  CHECK(backlogReserve() >= 0);
  CHECK(badWrites == 0);

  // Reboot: RAM is gone, the flash log isn't.
  backlogInit(11, &f);
  CHECK(backlogStats().flashPending == BL_SLOTS);
  std::vector<uint16_t> sums, wins;
  for (int round = 0; round < BL_SLOTS; round++) {
    stepUntilQuiet(true, false);   // connected: load the oldest
    sums.clear();
    wins.clear();
    drain(true, &sums, &wins);
    CHECK(wins.size() == 1);
    if (wins.empty()) break;
    CHECK(wins[0] == 100 + round);   // oldest first
    CHECK(sums.size() == 1);
    int s = -1;
    for (int i = 0; i < BL_SLOTS; i++)
      if (backlogSlot(i).state == BL_SENT) s = i;
    CHECK(s >= 0 && backlogSlot(s).backlog && backlogSlot(s).boot == 10);
    CHECK(s >= 0 && backlogSlot(s).summary.swing_kmh == 100 + round);
    CHECK(backlogAck(10, wins[0]));
  }
  CHECK(backlogStats().flashPending == 0);
  backlogInit(12, &f);
  CHECK(backlogStats().flashPending == 0);   // acks survive a reboot
  CHECK(badWrites == 0);
}

static void testFullLogOverwritesOldestOnlyWhenNeeded() {
  flash.assign(3 * BL_RECORD_SIZE, 0xFF);
  BacklogFlash f = {(uint32_t)flash.size(), fRead, fWrite, fErase};
  backlogInit(1, &f);
  for (int i = 0; i < 3; i++) {
    capture(200 + i);
    stepUntilQuiet(false, true);
  }
  CHECK(backlogStats().flashPending == 3);
  int before = erases;
  stepUntilQuiet(false, true);   // idle with a full log: nothing to make room for, nothing erased
  CHECK(erases == before);
  CHECK(backlogStats().flashLost == 0);
  capture(203);
  stepUntilQuiet(false, true);   // now it has to go
  CHECK(backlogStats().flashLost == 1);
  CHECK(backlogStats().flashPending == 3);
  // Not idle: no erase, so the window waits in RAM.
  capture(204);
  stepUntilQuiet(false, false);
  CHECK(backlogStats().flashPending == 3);
  CHECK(badWrites == 0);
}

static void testAckDuringSpill() {
  flash.assign(4 * BL_RECORD_SIZE, 0xFF);
  BacklogFlash f = {(uint32_t)flash.size(), fRead, fWrite, fErase};
  backlogInit(3, &f);
  for (int i = 0; i < BL_SLOTS; i++) capture(300 + i);
  drain(true);
  CHECK(backlogStep(true, false, now));   // RAM full: the spill of window 300 starts
  CHECK(backlogAck(3, 300));               // the ack arrives meanwhile
  stepUntilQuiet(true, false);
  CHECK(backlogStats().flashPending == 0);
  CHECK(badWrites == 0);
}

int main() {
  testAckedFlow();
  testPlainImpactMode();
  testRamFullWithoutFlashDropsNewest();
  testSpillAndReloadAcrossReboot();
  testFullLogOverwritesOldestOnlyWhenNeeded();
  testAckDuringSpill();
  printf(failures ? "%d FAILED\n" : "PASS\n", failures);
  return failures ? 1 : 0;
}
