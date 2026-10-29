import React from 'react';
import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { Backdrop, Title } from '../components/ui';
import { colors } from '../config/brand';
import { copy } from '../config/copy';
import { enter } from '../lib/anim';

// Black open, two lines. The second lands on the question the product answers.
export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const [a, b] = copy.hook.lines;
  return (
    <Backdrop glow={0.06}>
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', gap: 18 }}>
        <Title size={92} style={{ ...enter(frame, 4, 16), color: colors.muted }}>{a}</Title>
        <Title size={112} style={enter(frame, 40, 16)}>{b}</Title>
      </AbsoluteFill>
    </Backdrop>
  );
};
