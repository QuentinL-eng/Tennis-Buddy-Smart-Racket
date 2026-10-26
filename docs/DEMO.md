# Demo script (3 minutes)

**Before going on:** Mac app open full screen on the projector, racket connected (or Simulator as backup), Gemma
loaded on the Mac and iPhone, Watch on the presenter's non-playing wrist, a ball and a hanging blanket or a partner.

1. **The fork (15 s).** "We forked an open-source smart racket that sent one acceleration number over Wi-Fi and lit a
   red or green LED. We kept its idea and rebuilt everything around it." Show `legacy/` and the fork badge on GitHub.
2. **The trick: the racket (60 s).**
   - Pick up the racket: the 3D racket on screen moves with it. Hit **Recenter** first.
   - Start a session from the **Watch** (it also starts a Tennis workout).
   - Hit a ball into the blanket: the shot card pops up with ball speed, swing speed, spin, face angle, and the dot
     where the ball hit the strings. The card edge flashes **green** for the sweet spot, **red** for a mishit (the
     original project's LEDs, reborn). The Watch taps your wrist the same way.
   - Mention the hardware: two IMUs (gyro + 200 g accelerometer) streaming 1,000 samples/s from inside the handle.
3. **The treat: analytics (60 s).**
   - End the session on the Watch → History: shot mix, impact heat map per stroke, speed over the session.
   - Tap **Coach me**: Gemma 4 E2B, an open-weights model, writes the session report **on the device, offline**.
   - Insights → ask "What's my weakest stroke?" and "Plan my next drill".
4. **How accurate? (30 s).** Show the slide comparing app numbers with 240 fps slow-mo measurements.

**If Bluetooth fails:** Racket tab → Recorder → replay a recorded session (it plays exactly like the live racket), or
switch the source to Simulator.
