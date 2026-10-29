// Colours and fonts. Values come from the app's dark theme (apple/design/insights-f)
// and the website (--felt, --display, --sans). Change here, every scene follows.
export const colors = {
  bg: '#0B0C09',
  card: '#171913',
  track: '#2A2E20',
  text: '#F3F5EC',
  muted: '#A9AE9A',
  accent: '#DDE85B', // "felt" lime, the app's AccentColor
  accentDeep: '#C9D640',
  better: '#5EDC8A',
  worse: '#FF9A8D',
  score: '#B57AC9', // purple scoreboard in the glasses HUD
} as const;

export const fonts = {
  display: '"Bricolage Grotesque", "Arial Black", Arial, sans-serif',
  sans: '"DM Sans", "Helvetica Neue", Arial, sans-serif',
  mono: '"JetBrains Mono", Consolas, monospace',
} as const;

// Output formats. Add a vertical entry here and in Root.tsx for TikTok/Reels.
export const video = { width: 1920, height: 1080, fps: 30 } as const;
