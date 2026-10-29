import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Backdrop, Card, Kicker, Title } from '../components/ui';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { features } from '../config/timeline';
import { enter, pop, ramp } from '../lib/anim';

const c = copy.whatIf;
// Beat timings (frames)
const T = { ask: 20, tool: 55, result: 90, note: 140, press: 200, drill: 214 };

const Bar: React.FC<{ label: string; before: number; after: number; unit: string; t: number }> = ({ label, before, after, unit, t }) => {
  const max = after * 1.15;
  const now = Math.round(before + (after - before) * t);
  return (
    <div style={{ marginBottom: 22 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 30 }}>
        <span>{label}</span>
        <span><span style={{ color: colors.muted }}>{before} → </span><b>{now}</b> <span style={{ color: colors.muted }}>{unit}</span> <span style={{ color: colors.better, fontSize: 26 }}>▲ {Math.round(((after - before) / before) * 100)}%</span></span>
      </div>
      <div style={{ position: 'relative', height: 16, background: colors.track, borderRadius: 8, marginTop: 10 }}>
        <div style={{ position: 'absolute', height: '100%', width: `${(before / max) * 100}%`, background: '#5c6040', borderRadius: 8 }} />
        <div style={{ position: 'absolute', height: '100%', width: `${((before + (after - before) * t) / max) * 100}%`, background: colors.accent, borderRadius: 8, opacity: t > 0 ? 1 : 0 }} />
      </div>
    </div>
  );
};

/** Only drawn when features.showBallFlight is on (needs a flight model in ShotSimulator). */
const Flight: React.FC<{ t: number }> = ({ t }) => {
  const arc = (h: number, len: number) => `M20,150 Q${20 + len / 2},${150 - h} ${20 + len},150`;
  return (
    <svg width={760} height={170} style={{ marginBottom: 10 }}>
      <line x1={0} x2={760} y1={150} y2={150} stroke={colors.track} strokeWidth={3} />
      <path d={arc(160, 520)} fill="none" stroke="#5c6040" strokeWidth={4} strokeDasharray="10 8" />
      <path d={arc(170, 520 + 120 * t)} fill="none" stroke={colors.accent} strokeWidth={5} />
    </svg>
  );
};

// Muse Spark calls simulate_change on the player's own average shot, then plans a drill.
export const WhatIf: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const grow = ramp(frame, T.result + 10, T.result + 50);
  const thinking = frame >= T.tool && frame < T.result;
  const dots = '•••'.slice(0, 1 + (Math.floor(frame / 6) % 3));
  const press = frame >= T.press && frame < T.press + 8 ? 0.95 : 1;
  const drill = pop(frame, T.drill, fps);
  const remaining = Math.max(c.drillTarget - Math.floor(Math.max(0, frame - T.drill - 30) / 9), c.drillTarget - 3);

  return (
    <Backdrop glow={0.1}>
      <AbsoluteFill style={{ padding: '0 110px', width: 780, gap: 18, justifyContent: 'center' }}>
        <Kicker style={enter(frame, 4)}>{c.kicker}</Kicker>
        <Title size={70} style={enter(frame, 10)}>{c.title}</Title>
      </AbsoluteFill>
      <AbsoluteFill style={{ left: 900, width: 920, gap: 24, justifyContent: 'center' }}>
        <div style={{ ...enter(frame, 6), display: 'flex', alignItems: 'center', gap: 12, fontSize: 26, color: colors.muted }}>
          <span style={{ color: colors.accent, fontSize: 30 }}>✦</span>{c.status}
        </div>
        <div style={{ ...enter(frame, T.ask), alignSelf: 'flex-end', maxWidth: 680, background: colors.accent, color: '#11130c', fontSize: 32, fontWeight: 600, padding: '18px 26px', borderRadius: '26px 26px 6px 26px', lineHeight: 1.3 }}>{c.question}</div>
        <div style={{ ...enter(frame, T.tool), fontFamily: fonts.mono, fontSize: 24, color: colors.muted, background: colors.card, border: `1px solid ${colors.track}`, borderRadius: 12, padding: '10px 18px', alignSelf: 'flex-start' }}>
          <span style={{ color: colors.accent }}>{c.tool}</span>({c.toolArgs}){thinking ? `  ${dots}` : '  ✓'}
        </div>
        <Card style={{ ...enter(frame, T.result) }}>
          {features.showBallFlight && <Flight t={grow} />}
          {c.results.map((r) => <Bar key={r.label} {...r} t={grow} />)}
        </Card>
        <div style={{ display: 'flex', gap: 22, alignItems: 'stretch' }}>
          <div style={{ ...enter(frame, T.note + 20), transform: `scale(${press})`, background: colors.card, border: `2px solid ${colors.accent}`, color: colors.accent, fontSize: 30, fontWeight: 700, borderRadius: 18, padding: '20px 28px', alignSelf: 'flex-start' }}>
            ✦ {c.drillButton}
          </div>
          <Card style={{ flex: 1, opacity: drill, transform: `translateY(${(1 - drill) * 30}px)`, padding: '18px 26px', display: 'flex', alignItems: 'center', gap: 24 }}>
            <div style={{ textAlign: 'center' }}>
              <div style={{ fontFamily: fonts.display, fontSize: 76, fontWeight: 800, color: colors.accent, lineHeight: 1 }}>{remaining}</div>
              <div style={{ fontSize: 20, color: colors.muted }}>{c.drillRemaining}</div>
            </div>
            <div>
              <div style={{ fontSize: 30, fontWeight: 700 }}>{c.drillName}</div>
              <div style={{ fontSize: 22, color: colors.muted }}>{c.drillStart}</div>
            </div>
          </Card>
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
