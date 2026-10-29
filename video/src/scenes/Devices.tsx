import React from 'react';
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Backdrop, Kicker } from '../components/ui';
import { colors, fonts } from '../config/brand';
import { copy } from '../config/copy';
import { enter, pop, rand } from '../lib/anim';

const shot = copy.impact;
const SOURCE = { x: 210, y: 600 };
const TARGETS = [
  { x: 640, y: 560, at: 18 }, // phone
  { x: 1090, y: 600, at: 30 }, // watch
  { x: 1560, y: 560, at: 42 }, // glasses
];

/** Bluetooth packets: dots travelling from the handle to each device. */
const Stream: React.FC<{ frame: number }> = ({ frame }) => (
  <svg width={1920} height={1080} style={{ position: 'absolute', inset: 0 }}>
    {TARGETS.map((t, k) =>
      Array.from({ length: 10 }, (_, i) => {
        const p = ((frame - t.at + i * 9 + rand(i + k * 10) * 6) % 90) / 90;
        if (frame < t.at || p < 0) return null;
        const cx = SOURCE.x + (t.x - SOURCE.x) * p;
        const cy = SOURCE.y + (t.y - SOURCE.y) * p - Math.sin(p * Math.PI) * 140;
        return <circle key={`${k}-${i}`} cx={cx} cy={cy} r={5} fill={colors.accent} opacity={Math.sin(p * Math.PI)} />;
      }),
    )}
  </svg>
);

const Label: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ fontSize: 28, color: colors.muted, marginTop: 22, textAlign: 'center' }}>{children}</div>
);

export const Phone: React.FC = () => (
  <div style={{ width: 340, height: 700, borderRadius: 54, background: '#000', border: '10px solid #2b2d27', padding: '60px 26px 26px', display: 'flex', flexDirection: 'column', gap: 10 }}>
    <div style={{ fontFamily: fonts.display, fontSize: 40, fontWeight: 700 }}>Live</div>
    <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginTop: 20, fontSize: 26, fontWeight: 700 }}>
      {shot.stroke}
      <span style={{ fontSize: 18, color: colors.better, background: 'rgba(94,220,138,0.15)', padding: '3px 10px', borderRadius: 14 }}>{shot.badge}</span>
    </div>
    <div style={{ fontFamily: fonts.display, fontSize: 130, fontWeight: 800, lineHeight: 1 }}>{shot.speed}</div>
    <div style={{ fontSize: 22, color: colors.muted }}>{shot.unit} ball speed</div>
    <div style={{ height: 1, background: colors.track, margin: '18px 0' }} />
    <div style={{ fontSize: 22, color: colors.muted }}>{shot.sub}</div>
    <div style={{ flex: 1 }} />
    <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 16, color: colors.muted }}>
      {['Live', 'Together', 'History', 'Insights', 'Racket'].map((t) => <span key={t} style={{ color: t === 'Live' ? colors.accent : undefined }}>{t}</span>)}
    </div>
  </div>
);

export const Watch: React.FC = () => (
  <div style={{ width: 250, height: 300, borderRadius: 70, background: '#000', border: '12px solid #2b2d27', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
    <div style={{ fontSize: 22, color: colors.better }}>{shot.badge}</div>
    <div style={{ fontFamily: fonts.display, fontSize: 104, fontWeight: 800, lineHeight: 1 }}>{shot.speed}</div>
    <div style={{ fontSize: 24, color: colors.muted }}>{shot.unit}</div>
  </div>
);

export const Glasses: React.FC = () => (
  <div style={{ width: 520, height: 330, borderRadius: 24, overflow: 'hidden', position: 'relative', border: `2px solid ${colors.track}` }}>
    <Img src={staticFile('img/court.jpg')} style={{ width: '100%', height: '100%', objectFit: 'cover', filter: 'blur(1.5px) brightness(0.85)' }} />
    <div style={{ position: 'absolute', right: 26, top: 50, width: 270, padding: '14px 18px', borderRadius: 18, border: '2px solid rgba(94,220,138,0.8)', background: 'rgba(20,24,18,0.45)', backdropFilter: 'blur(6px)' }}>
      <div style={{ display: 'flex', gap: 8, fontSize: 20, fontWeight: 700, alignItems: 'center' }}>
        {shot.stroke}<span style={{ fontSize: 14, color: colors.better }}>{shot.badge}</span>
      </div>
      <div style={{ fontFamily: fonts.display, fontSize: 70, fontWeight: 800, lineHeight: 1 }}>{shot.speed}<span style={{ fontSize: 22, fontWeight: 400 }}> {shot.unit}</span></div>
      <div style={{ fontSize: 14, color: '#e6e6e6' }}>{shot.sub}</div>
    </div>
  </div>
);

// One shot fans out over Bluetooth to phone, watch and glasses.
export const Devices: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const devices = [
    { el: <Phone />, label: copy.devices.phone, x: 640 },
    { el: <Watch />, label: copy.devices.watch, x: 1090 },
    { el: <Glasses />, label: copy.devices.glasses, x: 1560 },
  ];
  const pulse = (frame % 30) / 30;
  return (
    <Backdrop glow={0.08}>
      <AbsoluteFill style={{ alignItems: 'center', paddingTop: 70 }}>
        <Kicker style={enter(frame, 4)}>{copy.devices.kicker}</Kicker>
      </AbsoluteFill>
      <Stream frame={frame} />
      {/* Handle with a Bluetooth pulse */}
      <div style={{ position: 'absolute', left: SOURCE.x - 34, top: SOURCE.y - 150, width: 68, height: 300, borderRadius: 20, background: 'linear-gradient(90deg,#1b1d17,#34372d,#1b1d17)', border: `2px solid ${colors.track}` }} />
      <div style={{ position: 'absolute', left: SOURCE.x - 60 - pulse * 60, top: SOURCE.y - 60 - pulse * 60, width: 120 + pulse * 120, height: 120 + pulse * 120, borderRadius: '50%', border: `3px solid ${colors.accent}`, opacity: 1 - pulse }} />
      {devices.map((d, i) => {
        const s = pop(frame, TARGETS[i].at + 20, fps);
        return (
          <div key={d.label} style={{ position: 'absolute', left: d.x, top: 560, transform: `translate(-50%,-50%) scale(${0.85 + 0.15 * s})`, opacity: s, display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
            {d.el}
            <Label>{d.label}</Label>
          </div>
        );
      })}
    </Backdrop>
  );
};
