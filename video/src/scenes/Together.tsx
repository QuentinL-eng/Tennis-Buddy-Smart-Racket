import React from 'react';
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from 'remotion';
import { Backdrop, Card, Kicker, Title } from '../components/ui';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { enter, pop, ramp } from '../lib/anim';

const c = copy.together;

// Two players' sessions side by side, Strava-style.
export const Together: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const grow = ramp(frame, 40, 80);
  const [a, b] = c.players;
  const stats = [
    { label: 'Shots', key: 'shots' as const, unit: '' },
    { label: 'Top ball speed', key: 'top' as const, unit: ` ${c.unit}` },
    { label: 'Sweet spot', key: 'sweet' as const, unit: '%' },
  ];
  return (
    <Backdrop glow={0.1}>
      <AbsoluteFill style={{ alignItems: 'center', paddingTop: 110, gap: 14 }}>
        <Kicker style={enter(frame, 4)}>Shared stats</Kicker>
        <Title size={96} style={enter(frame, 10)}>{c.title}</Title>
        <div style={{ ...enter(frame, 20), fontSize: 36, color: colors.muted }}>{c.sub}</div>
        <div style={{ display: 'flex', gap: 40, marginTop: 50 }}>
          {[a, b].map((p, i) => {
            const s = pop(frame, 26 + i * 8, fps);
            return (
              <Card key={p.name} style={{ width: 620, opacity: s, transform: `translateY(${(1 - s) * 40}px)` }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 18, marginBottom: 24 }}>
                  <div style={{ width: 64, height: 64, borderRadius: 32, background: i ? colors.track : colors.accent, color: i ? colors.text : '#11130c', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 30, fontWeight: 800 }}>{p.name[0]}</div>
                  <div style={{ fontSize: 40, fontWeight: 700 }}>{p.name}</div>
                </div>
                {stats.map((st) => {
                  const v = p[st.key], other = (i ? a : b)[st.key];
                  return (
                    <div key={st.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '12px 0', borderTop: `1px solid ${colors.track}` }}>
                      <span style={{ fontSize: 30, color: colors.muted }}>{st.label}</span>
                      <span style={{ fontFamily: fonts.display, fontSize: 48, fontWeight: 800, color: v >= other ? colors.accent : colors.text }}>{Math.round(v * grow)}{st.unit}</span>
                    </div>
                  );
                })}
              </Card>
            );
          })}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
