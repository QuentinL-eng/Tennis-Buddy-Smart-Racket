import React from 'react';
import { AbsoluteFill, OffthreadVideo, interpolate, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { colors, fonts } from '../config/brand';
import type { FootageEntry } from '../config/timeline';

/** Burned-in caption: most social views are muted. */
export const Caption: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [6, 16], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return (
    <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', paddingBottom: 72, opacity }}>
      <div style={{ fontFamily: fonts.sans, fontWeight: 600, fontSize: 40, color: colors.text, background: 'rgba(11,12,9,0.72)', padding: '14px 28px', borderRadius: 14, maxWidth: 1500, textAlign: 'center', lineHeight: 1.3 }}>
        {text}
      </div>
    </AbsoluteFill>
  );
};

/** Real footage if `file` is set, otherwise a placeholder card with the shot notes. */
export const FootageSlot: React.FC<{ entry: FootageEntry }> = ({ entry }) => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ background: colors.bg }}>
      {entry.file ? (
        <OffthreadVideo src={staticFile(`footage/${entry.file}`)} startFrom={Math.round((entry.from ?? 0) * fps)} muted={entry.muted ?? true} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
      ) : (
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', border: `4px dashed ${colors.track}`, fontFamily: fonts.sans, color: colors.muted, gap: 20, padding: 160, textAlign: 'center' }}>
          <div style={{ fontSize: 26, letterSpacing: 4, textTransform: 'uppercase', color: colors.accent }}>Real footage · {entry.seconds}s</div>
          <div style={{ fontFamily: fonts.display, fontSize: 64, fontWeight: 700, color: colors.text }}>{entry.footage}</div>
          <div style={{ fontSize: 34, lineHeight: 1.4, maxWidth: 1300 }}>{entry.shot}</div>
          <div style={{ fontSize: 24, fontFamily: fonts.mono }}>public/footage/{entry.footage}.mp4</div>
        </AbsoluteFill>
      )}
      {entry.caption && <Caption text={entry.caption} />}
    </AbsoluteFill>
  );
};
