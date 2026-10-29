import React from 'react';
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Backdrop, Title } from '../components/ui';
import { colors } from '../config/brand';
import { copy } from '../config/copy';
import { enter, pop } from '../lib/anim';

// One headline + the real tagline from the website.
export const Endcard: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = pop(frame, 4, fps);
  return (
    <Backdrop glow={0.2}>
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', gap: 22 }}>
        <Img src={staticFile('img/icon.png')} style={{ width: 170, height: 170, borderRadius: 40, transform: `scale(${s})` }} />
        <Title size={130} style={enter(frame, 12)}>{copy.endcard.name}</Title>
        <div style={{ ...enter(frame, 24), fontSize: 52, color: colors.accent, fontWeight: 600 }}>{copy.endcard.tagline}</div>
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', paddingBottom: 70 }}>
        <div style={{ ...enter(frame, 40), fontSize: 28, color: colors.muted }}>{copy.endcard.footer}</div>
      </AbsoluteFill>
    </Backdrop>
  );
};
