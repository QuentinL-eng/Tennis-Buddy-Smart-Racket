// Every word that appears on screen in the CGI scenes lives here. Spoken words: voiceover.ts.
// Numbers from git and hackathon.json are not here: they come from generated/facts.json (npm run assets).
//
// Rules we keep:
// - Never call the product a "coach" or "analyzer" (hackathon anti-project list).
// - UI labels copy the real app strings (quoted in comments with their source).
// - Example shots run through the real simulator (lib/sim.ts). To show your own, change the inputs below.
//   `npm run check` lists anything still marked as a sample.
import { applyDeltas, simulate, toMph, type SimDeltas, type SimInput } from '../lib/sim.ts';

// ---- Example shots: change these and every card, HUD and what-if follows. ----
const forehand: SimInput = { swingKmh: 75, pathDeg: 12, faceDeg: 2, contactXcm: -0.4, contactYcm: -2.1, incomingKmh: 43.2 };
const serve: SimInput = { swingKmh: 100, pathDeg: 10, faceDeg: 2, contactXcm: 0.5, contactYcm: -1.5, incomingKmh: 0 };
const whatIfChange: SimDeltas = { swingPercent: 5, contactYcm: 2 };

/** The Live card's fields for a simulated shot (ShotCard in the app). */
const card = (stroke: string, p: SimInput, sample: boolean) => {
  const r = simulate(p);
  return {
    stroke,
    badge: r.sweetSpot ? 'Sweet spot' : `${Math.round(Math.hypot(p.contactXcm, p.contactYcm))} cm off`,
    speed: Math.round(toMph(r.ballKmh)),
    unit: 'mph',
    sub: `${Math.round(r.spinRpm)} rpm ${r.spinType} · ${Math.round(toMph(p.swingKmh))} mph swing`,
    sample,
  };
};
const forehandCard = card('Forehand', forehand, false);
const before = simulate(forehand), after = simulate(applyDeltas(forehand, whatIfChange));

export const copy = {
  // Shot card over the real serve in the cold open. Replace with the numbers from your real serve, then set
  // `sample: false`. While it is true the card wears a SAMPLE tag and `npm run check` fails.
  coldOpenShot: card('Serve', serve, true),

  hook: {
    lines: ['Four hundred shots tonight.', 'Which ones were good?'],
  },

  reveal: {
    name: 'Tennis Buddee',
    tagline: 'A racket that feels every shot.',
  },

  insideHandle: {
    kicker: 'Inside the handle',
    title: 'A custom sensor insert',
    // `part` must match a group name in public/models/handle.json
    parts: [
      { part: 'imu', name: 'LSM6DSV320X', detail: '6-axis IMU + ±320 g high-g accelerometer' },
      { part: 'mic', name: 'INMP441 microphone', detail: 'Hears where the ball meets the strings' },
      { part: 'mcu', name: 'ESP32-C3', detail: 'Computes every shot on the racket' },
      { part: 'board', name: 'Custom control board', detail: 'Designed and assembled for this build' },
    ],
  },

  impact: {
    kicker: 'One shot, three signals',
    traces: ['Gyro', 'High-g accel', 'Microphone'],
    // Matches the Live / glasses HUD layout ("Forehand", "Sweet spot")
    ...forehandCard,
  },

  robotLab: {
    kicker: 'Ground truth',
    title: 'A 6-axis robot arm swings the racket',
    // True of the Oct 29 session (data/room-2026-10-29): the real arm struck no ball, so none is drawn.
    showBalls: false,
    bullets: [
      'Real Epson C8, real racket, real sensors',
      'Known motion to check the numbers against',
      'It helped catch a gyro reading 2× too high',
    ],
  },

  // The Demo's robot beat. The real arm struck no ball, so none is drawn. The gyro: apple/RacketKit/Tests/RacketKitTests/LabeledSessionTests.swift.
  robotTwin: {
    shots: [
      { clip: 'rt-arm', word: 'REAL ARM.', accent: false },
      { clip: 'rt-racket', word: 'REAL RACKET.', accent: false },
      { clip: 'rt-handle', word: 'REAL SENSORS.', accent: true },
    ],
    realLabel: '●  REAL  ·  EPSON C8',
    cgiLabel: '◆  CGI  ·  BUILT FROM OUR CAD',
    twin: 'DIGITAL TWIN.',
    tags: ['EPSON C8', '6 AXES', 'SMART HANDLE'],
    proof: ['KNOWN MOTION.', 'REAL DATA.'],
    trace: "GYRO  ·  THE RACKET'S OWN RECORDING",
    truth: 'GROUND TRUTH.',
    truthLine: 'It helped catch a gyro reading 2× too high.',
  },

  // docs/CLUB_2026-10-28.md, firmware/include/protocol.h, firmware/src/backlog.h
  clubFinding: {
    kicker: 'Real court',
    title: 'On court, the raw stream fell apart.',
    arrivedPercent: 17,
    arrivedLabel: 'of the 1 kHz stream reached the phone',
    pivot: 'So the racket computes every shot itself.',
    steps: [
      { big: '80 bytes', small: 'Shot summary, sent first' },
      { big: '448 ms', small: 'Raw window, acked and resent' },
      { big: '117', small: 'Windows kept in flash, no phone needed' },
    ],
  },

  // Measured results only. ml/runs/SUMMARY-20261028.md; the 1.83 cm comes from hackathon.json via facts.json.
  // The what-if score: README.md results table, tools/agent_eval.py --preset baseten.
  // When the IMU + mic sessions are scored, replace `distance` with them, and say "thrown balls" and how many hits.
  evidence: {
    kicker: 'Measured',
    title: 'The numbers, measured.',
    parity: { label: 'C++ on the racket and Python agree', detail: 'Same sweet-spot call on every clip. Max distance error 7e-7 cm.' },
    distance: { label: 'Distance from the sweet spot, from sound', medianCm: 2.41, medianLabel: 'Always guessing the median', detail: 'Mean distance error' },
    whatIf: { label: 'Muse what-if answers', percent: 87.7, detail: 'Strict all-pass on 243 cases, on open Muse Spark. 45 more lost to a proxy outage, excluded.' },
    source: '274 labelled clips · grouped 5-fold · ml/runs/SUMMARY-20261028.md · tools/agent_eval.py',
  },

  // On the racket: firmware/src/sweetspot.cpp, a ridge model. The older int8 MLP was never promoted (ml/README.md).
  // In the app: open Muse Spark on Baseten, per the owner: meta-models/muse-spark-open-1026 (the proxy's MUSE_MODEL and MUSE_BASE_URL secrets).
  twoModels: {
    kicker: 'Two models, one racket',
    title: 'Fast on the racket. Smart in the app.',
    racket: {
      where: 'On the racket',
      name: 'Our own ML model',
      lines: ['Runs on the ESP32-C3', 'Ridge regression on 156 sound features', 'Trained on our own labelled hits'],
    },
    app: {
      where: 'In the app',
      name: 'Open Muse Spark',
      lines: ['Meta\'s open model, served by Baseten', '10 tools, every number from a tool', 'Scored on 243 what-if cases'],
    },
  },

  // Every tool must appear once (npm run check compares this with hackathon.json).
  museAgent: {
    model: 'muse-spark-open-1026',
    kicker: 'An agent, not a chat box',
    groups: [
      { name: 'Your shots', tools: ['query_shots', 'list_shots', 'compare_sessions', 'get_session_digest'] },
      { name: 'The live racket', tools: ['get_live_state', 'read_live_sensors', 'get_racket_status'] },
      { name: 'Physics simulator', tools: ['simulate_change'] },
      { name: 'Memory', tools: ['recall_notes', 'remember_note'] },
    ],
    // The tool-call trace in README.md, from the generated dataset.
    question: 'I keep mishitting my backhand. What should I fix?',
    calls: [
      { tool: 'get_session_digest', args: '', result: 'backhand contact 2.0 cm toward the tip' },
      { tool: 'simulate_change', args: 'type: "backhand", contact_y_cm: -1.0', result: 'ball 149.6 → 151.3 km/h · spin 1,066 rpm' },
    ],
    answer: 'Move contact 1.0 cm back toward the center. The estimate says ball speed goes from 150 km/h to about 151 km/h, and spin holds.',
    traceNote: 'Trace from our 2,263-conversation tool-use dataset',
    rule: 'Every number must come from a tool',
  },

  // Real SAM 3.1 boxes on the real clip (scripts/sam-clip.mjs). ml/stroke_system/README.md for the counts.
  samTrack: {
    kicker: 'Meta SAM 3.1',
    title: 'Real video. Real boxes.',
    prompts: { racket: 'tennis racket', ball: 'tennis ball' },
    stat: '15,566 frame/prompt pairs in 62 video requests',
    contact: 'Contact',
    purpose: 'Pre-fills the contact labels',
  },

  // Mirrors GlassesHUD.swift field by field. A simulated view: film the real lens and it replaces this scene.
  glassesPov: {
    tag: 'Filmed on court · HUD simulated, real HUD fields',
    badge: 'Meta Ray-Ban Display · Meta Wearables Device Access Toolkit',
    elapsed: '12:48',
    idleTitle: 'Ready', // GlassesHUD.swift
    idleDetail: 'Hit a ball to see your shot', // GlassesHUD.swift
    detailSweet: `${forehandCard.speed} ${forehandCard.unit} · ${forehandCard.badge}`, // GlassesController.swift
    stroke: forehandCard.stroke,
    shots: 48,
    sweetPercent: 67,
    score: 'You 6 · Opp 4',
    points: '40 – 15',
    drillName: 'Sweet-spot forehands',
    drillTarget: 10,
    drillStart: 3,
  },

  builtProof: {
    kicker: 'Check our work',
    title: 'Every commit is public.',
    testsLabel: ['Swift tests', 'Python tests', 'Firmware = Python clips'],
    license: 'MIT',
    verify: 'python3 ml/test_parity.py  →  PASS',
  },

  // Text for the overlays placed in src/config/timeline.ts
  overlays: {
    hook: ['Hundreds of hits per match.', 'Which ones are good?'],
    deviceBadge: 'Meta Wearables Device Access Toolkit',
    filmBadge: 'Real Muse Spark script, on a demo forehand session',
    museCallouts: ['Muse tests changes', 'Live on Muse Spark Open', 'An estimate: +7% ball speed', 'Then it plans a drill', 'Ask it anything: tools first'],
    emuBadge: 'Recorded live on the online simulator, on a pro match replay',
    simCallouts: ['tennisbuddy.net/emulator', 'No racket needed', 'Real pro matches, tracked with SAM 3.1'],
    talkName: { name: 'Quentin Lynch', detail: 'Built Tennis Buddee' },
    // Each player's name and what they do. An empty detail shows the name alone.
    // Kellam's job title is about the person, not the product, so it's the one allowed use of the word.
    testimonial1: { name: 'Kellam Adams', detail: 'Part-time tennis coach' },
    testimonial2: { name: 'Josh Do', detail: '' },
  },

  devices: {
    kicker: 'Live, wherever you look',
    phone: 'iPhone',
    watch: 'Apple Watch',
    glasses: 'Meta Ray-Ban Display',
    tabs: ['Live', 'Score', 'Muse', 'Insights', 'Settings'], // TennisBuddyApp.swift
  },

  score: {
    title: 'Score by tapping the handle', // ScoreView.swift
    sub: 'No phone in your pocket. No arguing about the score.',
    you: 'YOU',
    opponent: 'OPPONENT',
  },

  whatIf: {
    kicker: 'What if…',
    title: 'Muse Spark predicts the shot before you change it',
    status: 'Muse Spark · online', // CoachModel
    question: 'What if I hit 2 cm closer to the sweet spot and swing 5% faster?',
    tool: 'simulate_change', // CoachTools.swift
    toolArgs: `swing_percent: ${whatIfChange.swingPercent}, contact_y_cm: ${whatIfChange.contactYcm}`,
    results: [
      { label: 'Ball speed', before: Math.round(toMph(before.ballKmh)), after: Math.round(toMph(after.ballKmh)), unit: 'mph' },
      { label: 'Spin', before: Math.round(before.spinRpm), after: Math.round(after.spinRpm), unit: 'rpm' },
    ],
    note: 'Estimate on an example forehand, not a measurement',
    drillButton: 'Next drill', // MuseScreen.swift
    drillName: 'Sweet-spot forehands',
    drillTarget: 10,
    drillStart: 'Start on Watch', // MuseScreen.swift
    drillRemaining: 'to go',
  },

  together: {
    title: 'Play together', // AccountView / Together tab
    sub: 'Like Strava, for tennis. Compare sessions and progress with friends.',
    players: [
      { name: 'You', shots: 214, top: 74, sweet: 63 },
      { name: 'Sam', shots: 186, top: 70, sweet: 58 },
    ],
    unit: 'mph',
  },

  endcard: {
    name: 'Tennis Buddee',
    tagline: 'Find the sweet spot.', // website <h1>
    site: 'tennisbuddy.net/emulator',
    tryIt: 'Try our online simulator and feel like a tennis pro. No racket needed.',
    footer: 'Built with Muse Spark · Meta Global AI Developer Hackathon',
  },
};
