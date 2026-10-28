// BLE protocol shared with the apps (see docs/PLAN.md, "BLE protocol").
// Keep in sync with apple/RacketKit/Sources/RacketKit/Protocol.swift.
#pragma once
#include <stdint.h>

#define TB_DEVICE_NAME   "Tennis Buddy"
#define TB_SERVICE_UUID  "7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_IMU_UUID      "7E5B0002-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_STATUS_UUID   "7E5B0003-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_CONTROL_UUID  "7E5B0004-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_SHOT_UUID     "7E5B0005-6B1D-4D8E-9C1A-7E5B7E5B0001"  // on-device ML verdict, notify
#define TB_TAP_UUID      "7E5B0006-6B1D-4D8E-9C1A-7E5B7E5B0001"  // handle tap gesture, notify

#define TB_FW_MAJOR 1
#define TB_FW_MINOR 3

#define TB_SAMPLES_PER_PACKET 8

// Control commands (first byte written to the control characteristic)
enum : uint8_t {
  TB_CMD_START_STREAM = 0x01,
  TB_CMD_STOP_STREAM  = 0x02,
  TB_CMD_H3LIS_RANGE  = 0x10,  // second byte: 0 = 100 g, 1 = 200 g, 3 = 400 g
  TB_CMD_GYRO_RANGE   = 0x11,  // second byte: 0 = ±2000 dps (16.4 LSB/dps), 1 = ±4000 dps (8.2 LSB/dps).
                               // Firmware 1.3+. Back to ±2000 dps when the last client disconnects, so an
                               // app that never sends this keeps the original units.
};

// Status flags
enum : uint8_t {
  TB_FLAG_MPU_OK   = 1 << 0,
  TB_FLAG_H3LIS_OK = 1 << 1,
  TB_FLAG_STREAMING = 1 << 2,
  TB_FLAG_GYRO_4000 = 1 << 3,  // gyro samples in this packet are 8.2 LSB/dps (±4000 dps), not 16.4
};

#pragma pack(push, 1)
// Units are those of the original MPU6050 + H3LIS331DL; the LSM6DSV320X firmware converts into them.
struct TBSample {
  int16_t ax, ay, az;  // low-g accel, 2048 LSB/g (±16 g)
  int16_t gx, gy, gz;  // gyro, 16.4 LSB/(deg/s) (±2000 deg/s), or 8.2 with TB_FLAG_GYRO_4000
  int16_t hx, hy, hz;  // high-g accel as H3LIS331DL counts, 12-bit left-aligned (>> 4), at the h3lis_range scale
};

struct TBPacket {
  uint16_t seq;
  uint32_t t0_us;      // micros() of the first sample; samples are 1 ms apart
  uint8_t count;       // valid samples (normally TB_SAMPLES_PER_PACKET)
  uint8_t flags;       // TB_FLAG_*
  TBSample s[TB_SAMPLES_PER_PACKET];
};

struct TBStatus {
  uint16_t battery_mv;
  uint8_t fw_major, fw_minor;
  uint8_t flags;
  uint8_t h3lis_range;  // 0 = 100 g, 1 = 200 g, 3 = 400 g
  uint16_t dropped;     // packets dropped because the BLE queue was full
};
// One verdict from the on-device sweet-spot model (firmware/src/sweetspot.cpp), sent once per detected impact.
struct TBShot {
  uint16_t seq;         // counts impacts since boot
  uint8_t sweet;        // 1 = sweet spot, 0 = off-center
  uint8_t off_pct;      // 0 if sweet; else 33..100, distance toward the frame (100 = at the frame)
  uint8_t confidence;   // 50..100 (%), confidence in the sweet/not-sweet call
  uint8_t level;        // impact loudness, 0..255 (255 = full scale; ~255 means the mic clipped)
};
// One handle-tap gesture (firmware/src/tap.cpp), sent once the taps stop: a single, double or triple tap.
// Swings and ball impacts are filtered out on the racket.
struct TBTap {
  uint16_t seq;         // counts gestures since boot
  uint8_t count;        // taps in the gesture: 1 = single, 2 = double, ...
  uint8_t strength;     // strongest tap's jolt, 0..255 (255 = 2 g or more above the resting level)
  uint8_t zone;         // where on the handle: 0 = unknown, 1 butt, 2 grip_60, 3 grip_120, 4 grip_180, 5 throat
  uint8_t confidence;   // 0..100 (%), confidence in the zone; 0 while the zone model is unfitted
  int8_t dir[3];        // strongest tap's push direction in accel (sensor) axes, unit vector x 127. Its sign
                        // depends on which of two opposite sides was hit, so the app compares |cos| to the
                        // calibrated wide-side and narrow-side axes.
};
#pragma pack(pop)

static_assert(sizeof(TBSample) == 18, "sample size");
static_assert(sizeof(TBPacket) == 152, "packet must fit one 185-byte iOS MTU");
static_assert(sizeof(TBStatus) == 8, "status size");
static_assert(sizeof(TBShot) == 6, "shot size");
static_assert(sizeof(TBTap) == 9, "tap size");
