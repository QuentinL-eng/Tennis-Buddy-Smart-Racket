// The sub-minute X cut: every word on screen, bar by bar. Built in src/hype/Viral.tsx, clips from scripts/cut-viral.py.
// Say "smart racket" and "predicts". Anything simulated says so on screen. No voiceover: X autoplays muted, so the type carries it.
export const viral = {
  // "Keep It Movin'" from bar 7, so the serve's contact lands on the drop at bar 9. 95 BPM, 21 bars = 53 s.
  song: { src: 'audio/keep-it-movin.mp3', bpm: 95, firstDownbeat: 0.386, startBar: 7, volume: 0.8 },
  bars: 21,

  hook: ['WE PUT A COMPUTER', 'INSIDE A TENNIS RACKET.'],

  // The real serve and forehand beside the app. Sync: config/liveTwin.json. Each contact is cut to land on beat 3 of its bar.
  twin: [
    { chip: 'REAL TIME', title: 'IT FEELS EVERY SHOT.' },
    { chip: '1/2 SPEED', title: 'SAME SWING. SAME MOMENT.' },
    { chip: '1/2 SPEED', title: 'SERVE. FOREHAND. LIVE.' },
  ],
  twinLabels: { court: 'ON COURT', app: 'IN THE APP' },

  handle: { title: '1,000 READINGS A SECOND.', label: '◆  CGI  ·  BUILT FROM OUR CAD' },
  build: { clips: ['bt-solder', 'bt-pcb', 'bt-pod', 'bt-code'], title: 'BUILT FROM SCRATCH.' },
  robot: ['TESTED ON', 'A ROBOT ARM.'],
  devices: { title: 'PHONE. WATCH. GLASSES.', badge: 'Meta Wearables Device Access Toolkit' },
  glasses: { title: 'READ IT BETWEEN POINTS.' },

  muse: {
    kicker: "META'S MUSE SPARK",
    first: 'IT TESTS CHANGES TO YOUR SWING.',
    second: 'THEN PREDICTS WHAT THEY DO.',
    stat: 'An estimate: +7% ball speed',
    badge: 'Recorded live on the online simulator, on a pro match replay',
    third: 'BEFORE YOU MAKE THEM.',
    filmBadge: 'Real Muse Spark script, on a demo forehand session',
  },
  score: { title: 'TAP THE HANDLE TO SCORE.' },
  sam: { title: 'TRACKED WITH META SAM 3.1.' },

  // Their own words, in their own voices.
  people: [
    { clip: 'vx-kellam', name: 'Kellam Adams', detail: 'Part-time tennis coach', line: "THE RACKET'S SUPER AWESOME. IT HELPS MY PLAY A LOT BETTER." },
    { clip: 'vx-josh', name: 'Josh Do', detail: '', line: "TENNIS BUDDEE'S GOT ME TEN TIMES BETTER." },
  ],

  cta: { first: 'TRY IT IN YOUR BROWSER.', second: 'NO RACKET NEEDED.', url: 'tennisbuddy.net/emulator' },
};
