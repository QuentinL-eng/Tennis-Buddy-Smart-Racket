#include "backlog.h"

#include <string.h>

#ifdef ARDUINO
#include <Arduino.h>
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
#define BL_LOCK() portENTER_CRITICAL(&mux)
#define BL_UNLOCK() portEXIT_CRITICAL(&mux)
#else
#define BL_LOCK()
#define BL_UNLOCK()
#endif

// Threads: the sampler reserves and captures slots, the shot task analyses them, the loop does everything else
// (sending, acks and resends, which main.cpp queues to it, and all flash access). State changes that cross
// threads happen under BL_LOCK.

static BacklogSlot slots[BL_SLOTS];
static uint16_t bootId;
static uint32_t nextOrder = 1;
static BacklogStats stats;

static const uint64_t ALL_CHUNKS = (TB_WINDOW_CHUNKS >= 64) ? ~0ull : ((1ull << TB_WINDOW_CHUNKS) - 1);
static_assert(TB_WINDOW_CHUNKS <= 64, "chunk bitmap");

// ---- Flash log ----
// Record: RecHeader, TBShotSummary, ImpactWindow, then at the end a commit word (written last) and an ack word.
// Both start erased (0xFFFFFFFF) and are cleared to 0; flash can clear bits without erasing.
static const uint32_t MAGIC = 0x31574254;   // "TBW1"
struct RecHeader {
  uint32_t magic;
  uint32_t serial;     // write order, never reused
  uint16_t boot;
  uint16_t seq;
  uint8_t summaryOk;
  uint8_t pad[3];
  uint32_t hitMs;
  uint64_t unixMs;
  uint32_t crc;        // of the summary and window
  uint32_t pad2;
};
static_assert(sizeof(RecHeader) == 40, "record header");
static const uint32_t OFF_SUMMARY = sizeof(RecHeader);
static const uint32_t OFF_WINDOW = OFF_SUMMARY + sizeof(TBShotSummary);
static const uint32_t DATA_END = OFF_WINDOW + sizeof(ImpactWindow);
static const uint32_t OFF_COMMIT = BL_RECORD_SIZE - 8, OFF_ACK = BL_RECORD_SIZE - 4;
static_assert(DATA_END <= OFF_COMMIT, "record too small for a window");

enum : uint8_t { R_UNKNOWN, R_ERASED, R_PENDING, R_DIRTY };
static const int MAX_RECS = 128;
static const BacklogFlash *fl = nullptr;
static int nrec = 0;
static uint8_t recState[MAX_RECS];
static uint32_t recSerial[MAX_RECS];
static uint16_t recBoot[MAX_RECS], recSeq[MAX_RECS];
static int head = 0;               // next record to write
static uint32_t nextSerial = 1;
// Spill in progress: slot spillSlot is being written to record head, page spillPage next.
static int spillSlot = -1, spillPage = 0;
static RecHeader spillHdr;
// Erase in progress: record eraseRec, sector eraseSector next.
static int eraseRec = -1, eraseSector = 0;

static uint32_t crc32(uint32_t crc, const void *data, size_t len) {
  const uint8_t *p = (const uint8_t *)data;
  crc = ~crc;
  while (len--) {
    crc ^= *p++;
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1)));
  }
  return ~crc;
}

static uint32_t recOff(int r) { return (uint32_t)r * BL_RECORD_SIZE; }

static void freeSlot(BacklogSlot &s) {
  BL_LOCK();
  s.state = BL_FREE;
  BL_UNLOCK();
}

void backlogInit(uint16_t boot, const BacklogFlash *flash) {
  bootId = boot;
  memset(&stats, 0, sizeof(stats));
  for (auto &s : slots) {
    s.state = BL_FREE;
    s.flashRec = -1;
  }
  fl = flash && flash->size >= BL_RECORD_SIZE ? flash : nullptr;
  nrec = fl ? (int)(fl->size / BL_RECORD_SIZE) : 0;
  if (nrec > MAX_RECS) nrec = MAX_RECS;
  spillSlot = eraseRec = -1;
  uint32_t maxSerial = 0;
  int maxRec = -1;
  for (int r = 0; r < nrec; r++) {
    RecHeader h;
    uint32_t words[2];
    recState[r] = R_UNKNOWN;
    recSerial[r] = 0;
    if (!fl->read(recOff(r), &h, sizeof(h)) || !fl->read(recOff(r) + OFF_COMMIT, words, sizeof(words))) continue;
    if (h.magic == MAGIC) {
      recSerial[r] = h.serial;
      recBoot[r] = h.boot;
      recSeq[r] = h.seq;
      recState[r] = (words[0] == 0 && words[1] == 0xFFFFFFFFu) ? R_PENDING : R_DIRTY;
      if (h.serial >= maxSerial) { maxSerial = h.serial; maxRec = r; }
    }
  }
  nextSerial = maxSerial + 1;
  head = maxRec < 0 ? 0 : (maxRec + 1) % (nrec ? nrec : 1);
}

BacklogSlot &backlogSlot(int i) { return slots[i]; }

int backlogReserve() {
  int found = -1;
  BL_LOCK();
  for (int i = 0; i < BL_SLOTS; i++)
    if (slots[i].state == BL_FREE) {
      slots[i].state = BL_FILLING;
      found = i;
      break;
    }
  BL_UNLOCK();
  return found;
}

void backlogRelease(int slot) {
  if (slot >= 0) freeSlot(slots[slot]);
}

void backlogCaptured(int slot, uint32_t nowMs, uint64_t unixMs, bool backlog) {
  BacklogSlot &s = slots[slot];
  s.summaryOk = s.summarySent = false;
  s.backlog = backlog;
  s.boot = bootId;
  s.hitMs = nowMs;
  s.unixMs = unixMs;
  s.flashRec = -1;
  s.pending = ALL_CHUNKS;
  s.sentAtMs = 0;
  BL_LOCK();
  s.order = nextOrder++;
  s.state = BL_CAPTURED;
  stats.captured++;
  BL_UNLOCK();
}

void backlogDropped() { stats.dropped++; }

int backlogNextCaptured() {
  int best = -1;
  BL_LOCK();
  for (int i = 0; i < BL_SLOTS; i++)
    if (slots[i].state == BL_CAPTURED && (best < 0 || slots[i].order < slots[best].order)) best = i;
  BL_UNLOCK();
  return best;
}

void backlogAnalyzed(int slot, bool ok) {
  BacklogSlot &s = slots[slot];
  s.summaryOk = ok;
  BL_LOCK();
  if (s.state == BL_CAPTURED) s.state = BL_READY;
  BL_UNLOCK();
}

BacklogMsg backlogNext(bool acked, uint32_t nowMs) {
  BacklogMsg m = {BacklogMsg::NONE, -1, -1};
  // Unacked windows go round again.
  if (acked)
    for (int i = 0; i < BL_SLOTS; i++) {
      BacklogSlot &s = slots[i];
      if (s.state == BL_SENT && i != spillSlot && nowMs - s.sentAtMs > BL_RESEND_MS) {
        s.pending = ALL_CHUNKS;
        s.state = BL_READY;
        stats.resent++;
      }
    }
  // Summaries first, oldest first: they are what the player sees.
  int oldest = -1;
  for (int i = 0; i < BL_SLOTS; i++) {
    BacklogSlot &s = slots[i];
    if (s.state != BL_READY || i == spillSlot) continue;
    if (acked && s.summaryOk && !s.summarySent && (m.slot < 0 || s.order < slots[m.slot].order)) {
      m.kind = BacklogMsg::SUMMARY;
      m.slot = i;
    }
    if (s.pending && (oldest < 0 || s.order < slots[oldest].order)) oldest = i;
  }
  if (m.kind == BacklogMsg::SUMMARY) return m;
  if (oldest < 0) return m;
  BacklogSlot &s = slots[oldest];
  int c = 0;
  while (!(s.pending >> c & 1)) c++;
  m.kind = BacklogMsg::CHUNK;
  m.slot = oldest;
  m.chunk = c;
  return m;
}

void backlogSent(const BacklogMsg &m, bool acked, uint32_t nowMs) {
  if (m.kind == BacklogMsg::NONE) return;
  BacklogSlot &s = slots[m.slot];
  if (m.kind == BacklogMsg::SUMMARY) {
    s.summarySent = true;
    return;
  }
  s.pending &= ~(1ull << m.chunk);
  if (s.pending) return;
  if (acked) {
    s.state = BL_SENT;
    s.sentAtMs = nowMs;
  } else {
    freeSlot(s);   // plain impact mode: fire and forget, as before 1.6
  }
}

static int findSlot(uint16_t boot, uint16_t seq) {
  for (int i = 0; i < BL_SLOTS; i++) {
    const BacklogSlot &s = slots[i];
    if ((s.state == BL_READY || s.state == BL_SENT) && s.boot == boot && s.win.seq == seq) return i;
  }
  return -1;
}

static void flashAck(int r) {
  if (r < 0 || r >= nrec || recState[r] != R_PENDING) return;
  uint32_t zero = 0;
  fl->write(recOff(r) + OFF_ACK, &zero, sizeof(zero));
  recState[r] = R_DIRTY;
}

bool backlogAck(uint16_t boot, uint16_t seq) {
  int i = findSlot(boot, seq);
  bool found = false;
  if (i >= 0) {
    BacklogSlot &s = slots[i];
    if (i == spillSlot) {   // the write in progress is no longer needed: leave the record half-written (dirty)
      recState[head] = R_DIRTY;
      head = (head + 1) % nrec;
      spillSlot = -1;
    }
    flashAck(s.flashRec);
    freeSlot(s);
    found = true;
  }
  for (int r = 0; r < nrec; r++)   // a copy may still sit in flash (spilled, then loaded and acked)
    if (recState[r] == R_PENDING && recBoot[r] == boot && recSeq[r] == seq) {
      flashAck(r);
      found = true;
    }
  if (found) stats.acked++;
  return found;
}

bool backlogResend(uint16_t boot, uint16_t seq, const uint8_t *chunks, int n) {
  int i = findSlot(boot, seq);
  if (i < 0) return false;
  BacklogSlot &s = slots[i];
  if (n == 0) {
    s.pending = ALL_CHUNKS;
  } else {
    for (int k = 0; k < n; k++)
      if (chunks[k] < TB_WINDOW_CHUNKS) s.pending |= 1ull << chunks[k];
  }
  s.state = BL_READY;
  stats.resent++;
  return true;
}

// ---- Flash housekeeping ----

static bool recordErased(int r) {
  static uint8_t buf[BL_PAGE];
  for (uint32_t o = 0; o < BL_RECORD_SIZE; o += sizeof(buf)) {
    if (!fl->read(recOff(r) + o, buf, sizeof(buf))) return false;
    for (uint32_t k = 0; k < sizeof(buf); k++)
      if (buf[k] != 0xFF) return false;
  }
  return true;
}

// One page of the record being spilled: header, summary and window laid end to end.
static void recordPage(int page, uint8_t *out) {
  const BacklogSlot &s = slots[spillSlot];
  uint32_t start = (uint32_t)page * BL_PAGE;
  memset(out, 0xFF, BL_PAGE);
  for (uint32_t k = 0; k < BL_PAGE; k++) {
    uint32_t o = start + k;
    if (o < OFF_SUMMARY) out[k] = ((const uint8_t *)&spillHdr)[o];
    else if (o < OFF_WINDOW) out[k] = ((const uint8_t *)&s.summary)[o - OFF_SUMMARY];
    else if (o < DATA_END) out[k] = ((const uint8_t *)&s.win)[o - OFF_WINDOW];
  }
}

static int pendingCount() {
  int n = 0;
  for (int r = 0; r < nrec; r++) n += recState[r] == R_PENDING;
  return n;
}

static int oldestPending() {
  int best = -1;
  for (int r = 0; r < nrec; r++)
    if (recState[r] == R_PENDING && (best < 0 || recSerial[r] < recSerial[best])) best = r;
  return best;
}

static bool anySlot(uint8_t state) {
  for (auto &s : slots)
    if (s.state == state) return true;
  return false;
}

bool backlogStep(bool connected, bool idle, uint32_t nowMs) {
  if (!fl || nrec == 0) {
    // No flash: when RAM is full the newest window is dropped by the sampler (backlogReserve fails).
    return false;
  }
  // 1. A spill in progress: one page per step, then the commit word.
  if (spillSlot >= 0) {
    static uint8_t page[BL_PAGE];
    const int pages = (DATA_END + BL_PAGE - 1) / BL_PAGE;
    if (spillPage < pages) {
      recordPage(spillPage, page);
      fl->write(recOff(head) + (uint32_t)spillPage * BL_PAGE, page, BL_PAGE);
      spillPage++;
      return true;
    }
    uint32_t zero = 0;
    fl->write(recOff(head) + OFF_COMMIT, &zero, sizeof(zero));
    BacklogSlot &s = slots[spillSlot];
    recState[head] = R_PENDING;
    recSerial[head] = spillHdr.serial;
    recBoot[head] = s.boot;
    recSeq[head] = s.win.seq;
    head = (head + 1) % nrec;
    freeSlot(s);
    spillSlot = -1;
    stats.spilled++;
    return true;
  }
  // 2. An erase in progress (only while idle): one sector per step.
  if (eraseRec >= 0) {
    if (!idle) return false;
    fl->erase(recOff(eraseRec) + (uint32_t)eraseSector * BL_SECTOR, BL_SECTOR);
    if (++eraseSector * BL_SECTOR >= BL_RECORD_SIZE) {
      recState[eraseRec] = R_ERASED;
      eraseRec = -1;
    }
    return true;
  }
  // 3. RAM full (or the phone is gone and the racket idle): spill the oldest window that isn't already in flash.
  bool full = !anySlot(BL_FREE);
  if (full || (!connected && idle)) {
    int victim = -1;
    for (int i = 0; i < BL_SLOTS; i++) {
      const BacklogSlot &s = slots[i];
      if ((s.state == BL_READY || s.state == BL_SENT) && (victim < 0 || s.order < slots[victim].order)) victim = i;
    }
    if (victim >= 0 && slots[victim].flashRec >= 0) {
      if (full) freeSlot(slots[victim]);   // already safe in flash: just make room
      return false;
    }
    if (victim >= 0) {
      if (recState[head] == R_UNKNOWN) recState[head] = recordErased(head) ? R_ERASED : R_DIRTY;
      if (recState[head] != R_ERASED && idle) {
        // No erased record ready (the log is full of unsent windows, or nothing was erased ahead): make one,
        // overwriting the oldest unsent window if that is what sits there.
        if (recState[head] == R_PENDING) stats.flashLost++;
        eraseRec = head;
        eraseSector = 0;
        return backlogStep(connected, idle, nowMs);
      }
      if (recState[head] == R_ERASED) {
        BacklogSlot &s = slots[victim];
        memset(&spillHdr, 0, sizeof(spillHdr));
        spillHdr.magic = MAGIC;
        spillHdr.serial = nextSerial++;
        spillHdr.boot = s.boot;
        spillHdr.seq = s.win.seq;
        spillHdr.summaryOk = s.summaryOk;
        spillHdr.hitMs = s.hitMs;
        spillHdr.unixMs = s.unixMs;
        spillHdr.crc = crc32(crc32(0, &s.summary, sizeof(s.summary)), &s.win, sizeof(s.win));
        spillSlot = victim;
        spillPage = 0;
        return backlogStep(connected, idle, nowMs);
      }
    }
  }
  // 4. While idle, keep the record at head (and one after it) erased so a spill never has to wait for an erase.
  if (idle) {
    for (int ahead = 0; ahead < 2 && ahead < nrec; ahead++) {
      int r = (head + ahead) % nrec;
      if (recState[r] == R_ERASED) continue;
      if (recState[r] == R_UNKNOWN) {
        recState[r] = recordErased(r) ? R_ERASED : R_DIRTY;
        return true;
      }
      if (recState[r] == R_PENDING) break;   // the log has wrapped onto unsent windows: erase only when needed
      eraseRec = r;
      eraseSector = 0;
      return backlogStep(connected, idle, nowMs);
    }
  }
  // 5. The link is free: bring back the oldest window from flash.
  if (connected && !anySlot(BL_READY) && !anySlot(BL_SENT) && !anySlot(BL_CAPTURED)) {
    int r = oldestPending();
    if (r < 0) return false;
    bool loaded = false;
    for (int i = 0; i < BL_SLOTS && !loaded; i++) {
      BacklogSlot &s = slots[i];
      BL_LOCK();
      bool mine = s.state == BL_FREE;
      if (mine) s.state = BL_FILLING;
      BL_UNLOCK();
      if (!mine) continue;
      RecHeader h;
      bool ok = fl->read(recOff(r), &h, sizeof(h)) && fl->read(recOff(r) + OFF_SUMMARY, &s.summary, sizeof(s.summary)) &&
                fl->read(recOff(r) + OFF_WINDOW, &s.win, sizeof(s.win)) &&
                h.crc == crc32(crc32(0, &s.summary, sizeof(s.summary)), &s.win, sizeof(s.win));
      if (!ok) {
        recState[r] = R_DIRTY;   // corrupt: drop it
        stats.flashLost++;
        freeSlot(s);
        return true;
      }
      s.summaryOk = h.summaryOk;
      s.summarySent = false;
      s.backlog = true;
      s.boot = h.boot;
      s.hitMs = h.hitMs;
      s.unixMs = h.unixMs;
      s.flashRec = r;
      s.pending = ALL_CHUNKS;
      BL_LOCK();
      s.order = nextOrder++;
      s.state = BL_READY;
      BL_UNLOCK();
      stats.loaded++;
      loaded = true;
    }
    return loaded;
  }
  return false;
}

BacklogStats backlogStats() {
  BacklogStats s = stats;
  s.flashPending = pendingCount();
  s.erasedAhead = 0;
  for (int a = 0; a < nrec && recState[(head + a) % nrec] == R_ERASED; a++) s.erasedAhead++;
  return s;
}
