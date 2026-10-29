// Small shared 2D pieces: background, kicker/title text, card.
import React from 'react';
import { AbsoluteFill } from 'remotion';
import { colors, fonts } from '../config/brand';

export const Backdrop: React.FC<{ children?: React.ReactNode; glow?: number }> = ({ children, glow = 0.18 }) => (
  <AbsoluteFill style={{ background: `radial-gradient(ellipse 70% 60% at 50% 45%, rgba(221,232,91,${glow}) 0%, rgba(11,12,9,0) 60%), ${colors.bg}`, color: colors.text, fontFamily: fonts.sans }}>
    {children}
  </AbsoluteFill>
);

export const Kicker: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ fontFamily: fonts.sans, fontSize: 26, fontWeight: 600, letterSpacing: 4, textTransform: 'uppercase', color: colors.accent, ...style }}>{children}</div>
);

export const Title: React.FC<{ children: React.ReactNode; size?: number; style?: React.CSSProperties }> = ({ children, size = 72, style }) => (
  <div style={{ fontFamily: fonts.display, fontSize: size, fontWeight: 700, lineHeight: 1.08, letterSpacing: -1.5, color: colors.text, ...style }}>{children}</div>
);

export const Card: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ background: colors.card, borderRadius: 22, padding: 28, border: `1px solid ${colors.track}`, ...style }}>{children}</div>
);
