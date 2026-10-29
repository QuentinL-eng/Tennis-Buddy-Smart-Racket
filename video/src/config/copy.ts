// Every word that appears on screen in the CGI scenes lives here.
//
// Rules we keep:
// - Never call the product a "coach" or "analyzer" (hackathon anti-project list).
// - UI labels copy the real app strings (quoted in comments with their source).
// - Numbers are sample data unless noted. Replace with real numbers from tonight's
//   session before final render (see SHOOT_PLAN.md, "Numbers to capture").

export const copy = {
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
      { part: 'mcu', name: 'ESP32-C3', detail: 'Streams every swing over Bluetooth LE' },
      { part: 'board', name: 'Custom control board', detail: 'Designed and assembled for this build' },
    ],
  },

  impact: {
    kicker: 'One shot, three signals',
    traces: ['Gyro', 'High-g accel', 'Microphone'],
    // Matches the Live / glasses HUD layout ("Forehand", "Sweet spot")
    stroke: 'Forehand',
    badge: 'Sweet spot',
    speed: 68,
    unit: 'mph',
    sub: '1840 rpm topspin · 74 mph swing',
  },

  robotLab: {
    kicker: 'Ground truth',
    title: 'A 6-axis robot arm swings the racket',
    bullets: [
      'Epson C8 arm, camera-guided strikes',
      'Hits a chosen point on the strings',
      'Labels every swing for the models',
    ],
  },

  devices: {
    kicker: 'Live, wherever you look',
    phone: 'iPhone',
    watch: 'Apple Watch',
    glasses: 'Meta Ray-Ban Display',
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
    toolArgs: 'contact −2 cm · swing +5%',
    results: [
      { label: 'Ball speed', before: 61, after: 67, unit: 'mph' },
      { label: 'Spin', before: 1840, after: 1930, unit: 'rpm' },
    ],
    drillButton: 'Plan my next drill', // CoachModel
    drillName: 'Sweet-spot forehands',
    drillTarget: 10,
    drillStart: 'Start drill (sends to Watch)',
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
    footer: 'Built with Muse Spark · Meta Global AI Developer Hackathon',
  },
};
