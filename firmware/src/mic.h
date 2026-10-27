// INMP441 I2S capture + impact trigger + sweet-spot inference.
#pragma once
#include <Arduino.h>
#include "protocol.h"

// Starts the I2S microphone and a background task. Each detected impact is classified on-device and a
// TBShot is pushed to `out` (queue of TBShot). Returns false if the I2S driver could not start.
bool micBegin(QueueHandle_t out);

// When enabled, every impact clip is also printed on USB serial as "CLIP,<hex>" so tools/collect_clips.py can
// save it as labelled training data. Toggle at runtime by sending 'c' over serial.
void micSetCollect(bool on);
bool micCollecting();

// Stats for the 1 Hz serial status line.
uint32_t micImpactCount();

// Noise floor (running mean |x|), loudest sample since the previous call, and the current impact trigger
// threshold, all in int16 sample units. A hit fires when a sample exceeds `trigger`.
struct MicLevel {
  int floor, peak, trigger;
};
MicLevel micLevel();
