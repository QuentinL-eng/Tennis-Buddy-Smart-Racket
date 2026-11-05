// ~27 s X clip: the 2026-10-29 robot-arm session (real footage) cut against CGI from the
// CAD, on "Ten". Timed in beats; copy, clips and beats come from src/config/robotHype.ts.
//
// Real -> CGI hand-offs are built to read as one shot:
//   - every clip gets the same grade, and grain + vignette sit over real and CGI alike
//   - CGI is drawn over the real room (the clip itself, or a still of it, blurred) rather than black
//   - each cut happens on matching framing and motion: the handle push, the arm, the racket throat
import React from 'react';
import { AbsoluteFill, Audio, Easing, Sequence, interpolate, spring, staticFile, useCurrentFrame } from 'remotion';
import { Effect } from '../components/Timeline';
import { Racket } from '../components/Racket';
import { Stage3D } from '../components/Stage3D';
import { colors, fonts } from '../config/brand';
import { gyroTrace } from '../config/gyro-trace';
import { robotHype as R, robotHypeCues } from '../config/robotHype';
import { useCad } from '../lib/models';
import { Part } from '../scenes/InsideHandle';
import { RobotArm } from '../scenes/RobotLab';
import { Big, Center, Grain, Small, useSlam } from './Hype';
import { Brackets, Clip, FPS, Flash, GRADE, Plate, SHADOW, Shade, Vignette, beatClock, clamp, inOut, makeDuck, mix, type V3, whipIn, whipOut } from './kit';

const { f, pulse, Shot } = beatClock(R.song.bpm); // ~14.28 frames per beat
export const robotHypeFrames = f(R.beats);

// Swing range of the CGI arm about J1 (radians), as in RobotLab.
export const BACK = -0.6, THROUGH = 0.6;

// ---------- 1. Hook: real cuts, one phrase per two beats ----------
const HookShot: React.FC<{ shot: (typeof R.hook.shots)[number] }> = ({ shot }) => {
  const slam = useSlam(0);
  return (
    <AbsoluteFill>
      <Clip name={shot.clip} len={f(2)} zoom={[1.14, 1]} />
      <Shade />
      <Center>
        <Big size={shot.word.length > 10 ? 175 : 210} color={'accent' in shot ? colors.accent : colors.text} style={{ ...slam, textShadow: SHADOW }}>{shot.word}</Big>
      </Center>
    </AbsoluteFill>
  );
};

// ---------- 2. Twin: real arm, whip-pan cut to its CGI twin, which swings on the drop ----------
// The racket CAD lies along scene Z (handle -1.5 .. tip +1.5) at x ~ -2.4. From the -X side
// the handle is screen-left and the head screen-right with the arm behind, as in the real shot.
const TWIN_CAM = { from: [-5.6, 1.9, 0.4] as V3, to: [-4.9, 1.6, -0.2] as V3, target: [-2.0, 1.25, -0.2] as V3, fov: 40 };
const Twin: React.FC = () => {
  const frame = useCurrentFrame();
  const t = R.twin;
  const b = (beat: number) => f(beat - t.at[0]);
  const cut = b(t.whip), contact = b(t.contact), end = b(t.at[1]);
  const scan = interpolate(frame, [b(t.scan[0]), b(t.scan[1])], [0, 1], { ...clamp, easing: inOut });
  // Wind back after the cut, then whip through contact on the drop.
  const angle = frame < contact - 6
    ? interpolate(frame, [cut, contact - 6], [0, BACK], { ...clamp, easing: inOut })
    : BACK + (THROUGH - BACK) * (0.5 + 0.5 * Math.tanh((frame - contact + 1) / 2.2) / Math.tanh(3));
  const push = interpolate(frame, [contact - 2, contact + 10], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  const cam = mix(mix(TWIN_CAM.from, TWIN_CAM.to, interpolate(frame, [cut, end], [0, 1], clamp)), TWIN_CAM.target, push * 0.18);
  const shake = frame >= contact && frame < contact + 8 ? Math.sin(frame * 7.3) * 14 * (1 - (frame - contact) / 8) : 0;
  const name = useSlam(b(t.scan[1]) - 3);
  const tagIn = (i: number) => interpolate(frame, [b(t.scan[1]) + i * 4, b(t.scan[1]) + 6 + i * 4], [0, 1], clamp);
  const corner: React.CSSProperties = { position: 'absolute', left: 110, top: 100, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 3, color: colors.accent };
  return (
    <AbsoluteFill style={{ transform: `translate(${shake}px, ${-shake / 2}px)` }}>
      {frame < cut ? (
        <AbsoluteFill style={whipOut(frame, cut)}>
          <Clip name={t.clip} len={cut} zoom={[1, 1.1]} origin="60% 45%" />
          <div style={{ ...corner, color: colors.text }}>{t.real}</div>
        </AbsoluteFill>
      ) : (
        <AbsoluteFill style={{ ...whipIn(frame, cut), ...whipOut(frame, end) }}>
          {/* the real room keeps moving behind the CGI: the same clip, blurred */}
          <Clip name={t.clip} len={end} zoom={[1, 1.2]} origin="60% 45%" blur={20} />
          <AbsoluteFill style={{ background: 'rgba(11,12,9,0.5)' }} />
          <AbsoluteFill style={{ filter: `${GRADE} blur(0.5px)` }}>
            <Stage3D camera={cam} target={TWIN_CAM.target} fov={TWIN_CAM.fov} rim="#ffe9c9" envIntensity={0.75}>
              <RobotArm angle={angle} grid={false} racket="blue" racketGlow={Math.max(0, 1 - Math.abs(frame - contact) / 6)} />
            </Stage3D>
          </AbsoluteFill>
          {/* scan pass: lines left behind it, a lime edge on it */}
          <AbsoluteFill style={{ clipPath: `inset(0 ${(1 - scan) * 100}% 0 0)`, background: 'repeating-linear-gradient(0deg, rgba(221,232,91,0.07) 0 2px, transparent 2px 5px)', mixBlendMode: 'screen' }} />
          {scan > 0 && scan < 1 && (
            <>
              <div style={{ position: 'absolute', top: 0, bottom: 0, left: scan * 1920 - 240, width: 240, background: 'linear-gradient(90deg, transparent, rgba(221,232,91,0.2))' }} />
              <div style={{ position: 'absolute', top: 0, bottom: 0, left: scan * 1920 - 2, width: 4, background: colors.accent, boxShadow: `0 0 30px 8px ${colors.accent}` }} />
            </>
          )}
          <div style={corner}>{t.cgiLabel}</div>
          <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'flex-end', padding: '0 110px 90px 0', gap: 18 }}>
            <div style={{ display: 'flex', gap: 14 }}>
              {t.tags.map((tag, i) => (
                <div key={tag} style={{ opacity: tagIn(i), transform: `translateY(${(1 - tagIn(i)) * 20}px)`, fontFamily: fonts.mono, fontSize: 26, letterSpacing: 2, color: colors.accent, border: `1.5px solid ${colors.accent}`, borderRadius: 30, padding: '8px 18px', background: 'rgba(11,12,9,0.5)' }}>{tag}</div>
              ))}
            </div>
            {frame >= b(t.scan[1]) - 3 && <Big size={130} color={colors.accent} style={{ ...name, transformOrigin: 'right center', textShadow: SHADOW }}>{t.cgi}</Big>}
          </AbsoluteFill>
        </AbsoluteFill>
      )}
      <Flash at={contact} len={8} peak={0.55} />
    </AbsoluteFill>
  );
};

// ---------- 3. What the racket measures: one real cut per beat, viewfinder HUD ----------
const Measure: React.FC<{ shot: (typeof R.measures.shots)[number]; i: number; len: number }> = ({ shot, i, len }) => {
  const frame = useCurrentFrame();
  const slam = useSlam(0);
  const last = i === R.measures.shots.length - 1;
  const n = R.measures.shots.length - 1;
  const t = (f(R.measures.at[0]) + f(i) + frame) / FPS;
  return (
    <AbsoluteFill style={i === 0 ? whipIn(frame, 0) : undefined}>
      <Clip name={shot.clip} len={len} zoom={last ? [1.2, 1] : [1.16, 1.02]} ease={Easing.out(Easing.cubic)} />
      {last ? (
        <>
          <Shade amount={0.45} />
          <Center><Big size={250} color={colors.accent} style={{ ...slam, textShadow: SHADOW }}>{shot.tag}</Big></Center>
        </>
      ) : (
        <>
          <AbsoluteFill style={{ background: 'linear-gradient(0deg, rgba(0,0,0,0.55), transparent 45%)' }} />
          <Brackets />
          <div style={{ position: 'absolute', left: 110, top: 100, fontFamily: fonts.mono, fontSize: 26, color: colors.text, display: 'flex', gap: 16, alignItems: 'center' }}>
            <div style={{ width: 16, height: 16, borderRadius: 8, background: '#ff4a3d', opacity: frame % 16 < 10 ? 1 : 0.2 }} />
            REC  00:00:{t.toFixed(2).padStart(5, '0')}
          </div>
          <div style={{ position: 'absolute', right: 110, top: 100, fontFamily: fonts.mono, fontSize: 26, color: colors.accent }}>{String(i + 1).padStart(2, '0')} / {String(n).padStart(2, '0')}</div>
          <div style={{ position: 'absolute', left: 110, bottom: 110 }}>
            <div style={{ fontFamily: fonts.mono, fontSize: 26, letterSpacing: 4, color: colors.accent, marginBottom: 10 }}>MEASURING ▸</div>
            <Big size={140} style={{ ...slam, transformOrigin: 'left center', textShadow: SHADOW }}>{shot.tag}</Big>
          </div>
        </>
      )}
    </AbsoluteFill>
  );
};
const Measures: React.FC = () => {
  let at = R.measures.at[0];
  return (
    <>
      {R.measures.shots.map((shot, i) => {
        const beats = ('beats' in shot ? shot.beats : undefined) ?? 1;
        const s = <Shot key={i} at={[at, at + beats]}><Measure shot={shot} i={i} len={f(beats)} /></Shot>;
        at += beats;
        return s;
      })}
    </>
  );
};

// ---------- 4. Into the handle: push into the real pod until it goes black, open up inside the CAD ----------
// The black box on the racket is the external mount (not in the CAD; the CAD insert is two thin
// shells inside the handle), so this cut matches on darkness instead of shape: the real push ends
// with the matte pod filling the frame, and the CGI comes up out of black already inside.
const POD = { origin: '40% 56%', zoom: 4.6 }; // pod centre in the clip, and how far to push to fill the frame with it
const HANDLE_CAM = { from: [1.1, 0.75, 2.6] as V3, fromTarget: [0.9, 0, 0] as V3, to: [1.3, 1.5, 4.4] as V3, toTarget: [1.3, 0.05, 0] as V3, fov: 30 };
const Handle: React.FC = () => {
  const frame = useCurrentFrame();
  const h = R.handle;
  const cut = f(h.cut - h.at[0]);
  const len = f(h.at[1] - h.at[0]);
  const cad = useCad('handle');
  const k = frame - cut;
  const explode = interpolate(k, [0, f(1.6)], [0.25, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  const move = interpolate(k, [0, len - cut], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  const lift = 22 * explode;
  const imu = k > f(1.5) ? 0.5 + 0.5 * pulse(frame) : 0;
  const big = useSlam(cut + 3);
  const line = useSlam(cut + f(1));
  const sub = interpolate(k, [f(2), f(2) + 8], [0, 1], clamp);
  // to black as the push fills the frame with the pod, then up from black inside the handle
  const dark = k < 0 ? interpolate(frame, [cut - 7, cut], [0, 1], clamp) : interpolate(k, [0, 8], [1, 0], clamp);
  return (
    <AbsoluteFill>
      {frame < cut ? (
        <Clip name={h.clip} len={cut} zoom={[1, POD.zoom]} origin={POD.origin} ease={Easing.in(Easing.cubic)} />
      ) : (
        <AbsoluteFill>
          <Plate name="rh-plate-handle" blur={26} dim={0.62} zoom={1.6} />
          <Stage3D camera={mix(HANDLE_CAM.from, HANDLE_CAM.to, move)} target={mix(HANDLE_CAM.fromTarget, HANDLE_CAM.toTarget, move)} fov={HANDLE_CAM.fov} rim="#ffe9c9" envIntensity={0.6}>
            {cad && (
              <group position={[0, 0, 0]} rotation={[0.1 + 0.08 * move, -0.3 - 0.25 * move, 0]}>
                <group scale={0.036} rotation={[0, Math.PI / 2, 0]}>
                  <group position={cad.center.clone().negate().toArray()}>
                    <Part group={cad.groups.shell1} offset={[0, lift, 0]} ghost={explode > 0.05} />
                    <Part group={cad.groups.shell2} offset={[0, -lift, 0]} ghost={explode > 0.05} />
                    <Part group={cad.groups.screws} offset={[0, -lift, 0]} />
                    <Part group={cad.groups.button} offset={[0, lift, 0]} />
                    <Part group={cad.groups.board} />
                    <Part group={cad.groups.imu} offset={[0, 6 * explode, 0]} glow={imu} />
                    <Part group={cad.groups.mic} offset={[0, 4 * explode, 0]} />
                    <Part group={cad.groups.mcu} offset={[0, 4 * explode, 0]} />
                  </group>
                </group>
              </group>
            )}
          </Stage3D>
          <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'flex-end', padding: '0 120px', textAlign: 'right' }}>
            <Big size={300} color={colors.accent} style={{ ...big, transformOrigin: 'right center', textShadow: SHADOW }}>{h.big}</Big>
            <Big size={88} style={{ ...line, transformOrigin: 'right center', marginTop: 10, textShadow: SHADOW }}>{h.line}</Big>
            <Small style={{ opacity: sub, marginTop: 18 }}>{h.sub}</Small>
          </AbsoluteFill>
        </AbsoluteFill>
      )}
      <AbsoluteFill style={{ background: '#050504', opacity: dark, pointerEvents: 'none' }} />
    </AbsoluteFill>
  );
};

// ---------- 5. Ground truth: real arm | CGI twin, swinging on the racket's own gyro peaks ----------
export const PANEL_W = 608; // 1080 x 1920 portrait shown full height
export const TRACE_PEAKS = gyroTrace
  .map((v, i) => ({ v, i }))
  .filter(({ v, i }) => v > 12 && gyroTrace.slice(Math.max(0, i - 40), i + 40).every((u) => u <= v))
  .map(({ i }) => i);
export const Trace: React.FC<{ progress: number; width: number; height: number }> = ({ progress, width, height }) => {
  const n = gyroTrace.length, max = Math.max(...gyroTrace);
  const shown = Math.max(2, Math.floor(progress * n));
  const pts = gyroTrace.slice(0, shown).map((v, i) => `${i ? 'L' : 'M'}${((i / (n - 1)) * width).toFixed(1)},${(height - (v / max) * (height - 12)).toFixed(1)}`).join(' ');
  const head = gyroTrace[shown - 1];
  return (
    <svg width={width} height={height} style={{ overflow: 'visible' }}>
      <line x1={0} x2={width} y1={height} y2={height} stroke={colors.track} strokeWidth={2} />
      <path d={pts} stroke={colors.accent} strokeWidth={3.5} fill="none" strokeLinejoin="round" />
      <circle cx={((shown - 1) / (n - 1)) * width} cy={height - (head / max) * (height - 12)} r={9} fill={colors.accent} style={{ filter: `drop-shadow(0 0 10px ${colors.accent})` }} />
    </svg>
  );
};
const Truth: React.FC = () => {
  const frame = useCurrentFrame();
  const t = R.truth;
  const len = f(t.at[1] - t.at[0]);
  const progress = frame / len;
  const toFrame = (i: number) => (i / (gyroTrace.length - 1)) * len;
  // CGI twin: alternate forehand/backhand through each gyro peak.
  let angle = BACK;
  TRACE_PEAKS.forEach((pk, k) => {
    const s = 0.5 + 0.5 * Math.tanh((frame - toFrame(pk)) / 2.5);
    angle += (k % 2 ? BACK - THROUGH : THROUGH - BACK) * s;
  });
  const hit = Math.max(0, ...TRACE_PEAKS.map((pk) => 1 - Math.abs(frame - toFrame(pk)) / 6));
  const line = Math.min(t.lines.length - 1, Math.floor(frame / f(2)));
  const slam = useSlam(f(line * 2));
  const label: React.CSSProperties = { fontFamily: fonts.mono, fontSize: 24, letterSpacing: 3, color: colors.accent, background: 'rgba(11,12,9,0.6)', padding: '6px 14px', borderRadius: 6 };
  return (
    <AbsoluteFill>
      <Plate name="rh-plate-lab" blur={24} dim={0.6} />
      <div style={{ position: 'absolute', left: 420, top: 60, width: 1920, height: 1080 }}>
        <Stage3D camera={[-1.2 + Math.sin(-0.95 + progress * 0.3) * 6.4, 1.4, 0.3 + Math.cos(-0.95 + progress * 0.3) * 6.4]} target={[-1.2, 0.25, 0.3]} fov={38} rim="#ffe9c9" envIntensity={0.75}>
          <RobotArm angle={angle} grid={false} racket="blue" racketGlow={hit} />
        </Stage3D>
      </div>
      <div style={{ position: 'absolute', left: 0, top: 0, width: PANEL_W, height: 1080, overflow: 'hidden', boxShadow: '20px 0 60px rgba(0,0,0,0.6)' }}>
        <Clip name={t.clip} len={len} zoom={[1, 1.06]} />
        <div style={{ position: 'absolute', left: 30, top: 30, ...label }}>REAL</div>
      </div>
      <div style={{ position: 'absolute', left: PANEL_W + 40, top: 30, ...label }}>CGI TWIN</div>
      <div style={{ position: 'absolute', left: PANEL_W + 90, right: 90, top: 90, textAlign: 'right' }}>
        <Big key={line} size={96} style={{ ...slam, transformOrigin: 'right center', textShadow: SHADOW }}>{t.lines[line]}</Big>
      </div>
      <div style={{ position: 'absolute', left: PANEL_W + 90, right: 90, bottom: 70 }}>
        <div style={{ fontFamily: fonts.mono, fontSize: 22, letterSpacing: 3, color: colors.muted, marginBottom: 12 }}>{t.trace}</div>
        <Trace progress={progress} width={1920 - PANEL_W - 180} height={170} />
      </div>
    </AbsoluteFill>
  );
};

// ---------- 6. Test matrix: wall of real clips, then the line ----------
const Matrix: React.FC = () => {
  const frame = useCurrentFrame();
  const m = R.matrix;
  const b = (beat: number) => f(beat - m.at[0]);
  const step = 0.4375; // nine tiles across four beats
  const dim = interpolate(frame, [b(m.lineAt) - 2, b(m.lineAt) + 4], [0, 0.66], clamp);
  const line = useSlam(b(m.lineAt));
  const len = f(m.at[1] - m.at[0]);
  return (
    <AbsoluteFill>
      <AbsoluteFill style={{ transform: `scale(${interpolate(frame, [0, len], [1, 1.08])})` }}>
        {m.tiles.map((tile, i) => {
          const start = f(i * step);
          const pop = spring({ frame: frame - start, fps: FPS, config: { damping: 13, stiffness: 200 } });
          const edge = frame >= start ? Math.exp(-(frame - start) / 5) : 0;
          return (
            <div key={tile} style={{ position: 'absolute', left: (i % 3) * 640, top: Math.floor(i / 3) * 360, width: 640, height: 360, opacity: frame < start ? 0 : 1, transform: `scale(${0.7 + 0.3 * pop})`, outline: `3px solid rgba(221,232,91,${edge})`, outlineOffset: -3, overflow: 'hidden' }}>
              <Sequence from={start} layout="none">
                <Clip name={tile} len={len} zoom={[1.1, 1]} />
              </Sequence>
            </div>
          );
        })}
      </AbsoluteFill>
      <AbsoluteFill style={{ background: `rgba(11,12,9,${dim})` }} />
      {frame >= b(m.lineAt) && (
        <Center style={{ flexDirection: 'column' }}>
          <div style={line}>
            <Big size={190} style={{ textShadow: SHADOW }}>{m.line[0]}</Big>
            <Big size={250} color={colors.accent} style={{ textShadow: SHADOW }}>{m.line[1]}</Big>
          </div>
        </Center>
      )}
    </AbsoluteFill>
  );
};

// ---------- 7. Finale: down the real throat, match cut to the CGI racket, then the name ----------
// CGI camera starts below the throat looking up the shaft (like the POV clip), then pulls back.
const FIN_CAM = { from: [0.02, -1.05, 0.42] as V3, fromTarget: [0, 0.35, -0.05] as V3, to: [0, 0.1, 6.1] as V3, toTarget: [0, 0.05, 0] as V3 };
const Finale: React.FC = () => {
  const frame = useCurrentFrame();
  const fin = R.finale;
  const b = (beat: number) => f(beat - fin.at[0]);
  const cut = b(fin.cut);
  const k = frame - cut;
  const pull = interpolate(k, [0, f(2.5)], [0, 1], { ...clamp, easing: inOut });
  const slide = interpolate(k, [f(1.5), f(3)], [0, 1], { ...clamp, easing: inOut });
  const panelW = interpolate(k, [0, 9], [PANEL_W, 1920], { ...clamp, easing: Easing.out(Easing.cubic) });
  const left = useSlam(0);
  const right = useSlam(f(1));
  const name = useSlam(cut + f(2));
  const appear = (beat: number) => ({ opacity: interpolate(k, [f(beat), f(beat) + 6], [0, 1], clamp) });
  const blurIn = interpolate(frame, [cut - 5, cut], [0, 8], clamp);
  return (
    <AbsoluteFill>
      {frame < cut ? (
        <AbsoluteFill style={{ filter: blurIn ? `blur(${blurIn}px)` : undefined }}>
          <Clip name={fin.clip} len={cut} zoom={[1.3, 1.5]} blur={30} />
          <AbsoluteFill style={{ background: 'rgba(11,12,9,0.5)' }} />
          <div style={{ position: 'absolute', left: (1920 - PANEL_W) / 2, top: 0, width: PANEL_W, height: 1080, overflow: 'hidden', boxShadow: '0 0 80px rgba(0,0,0,0.7)' }}>
            <Clip name={fin.clip} len={cut} zoom={[1, 1.22]} origin="50% 62%" ease={Easing.in(Easing.quad)} />
          </div>
          <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center' }}>
            <div style={{ width: (1920 - PANEL_W) / 2, paddingRight: 40, textAlign: 'right' }}>
              <Big size={104} style={{ ...left, transformOrigin: 'right center', textShadow: SHADOW, whiteSpace: 'nowrap' }}>{fin.pov[0]}</Big>
            </div>
            <div style={{ width: PANEL_W }} />
            <div style={{ width: (1920 - PANEL_W) / 2, paddingLeft: 40 }}>
              <Big size={104} color={colors.accent} style={{ ...right, transformOrigin: 'left center', textShadow: SHADOW, whiteSpace: 'nowrap' }}>{fin.pov[1]}</Big>
            </div>
          </AbsoluteFill>
        </AbsoluteFill>
      ) : (
        <AbsoluteFill>
          <AbsoluteFill style={{ background: colors.bg }} />
          {/* the real room behind the CGI at the cut, fading out as the camera pulls back */}
          <AbsoluteFill style={{ opacity: 1 - pull }}>
            <Clip name={fin.clip} len={b(fin.at[1])} zoom={[1.5, 1.7]} blur={30} />
            <AbsoluteFill style={{ background: 'rgba(11,12,9,0.5)' }} />
          </AbsoluteFill>
          <AbsoluteFill style={{ background: `radial-gradient(ellipse 70% 60% at 30% 50%, rgba(221,232,91,${0.1 * slide}), rgba(11,12,9,0) 65%)` }} />
          <div style={{ position: 'absolute', top: 0, bottom: 0, left: (1920 - panelW) / 2, width: panelW, overflow: 'hidden' }}>
            <div style={{ position: 'absolute', top: 0, left: -(1920 - panelW) / 2, width: 1920, height: 1080 }}>
              <Stage3D camera={mix(FIN_CAM.from, FIN_CAM.to, pull)} target={mix(FIN_CAM.fromTarget, FIN_CAM.toTarget, pull)} fov={interpolate(pull, [0, 1], [62, 32])} env="studio" envIntensity={1.4} hero>
                <pointLight position={[-0.6, 2.2, -1.8]} intensity={40} distance={8} color="#ffffff" />
                <Racket finish="blue" position={[-1.25 * slide, 0, 0]} rotation={[0.1 * pull, 0.3 * pull + k * 0.005, -0.16 * slide]} glow={0.4 + 0.6 * pulse(frame)} />
              </Stage3D>
            </div>
          </div>
          <AbsoluteFill style={{ justifyContent: 'center', paddingLeft: 860, gap: 18 }}>
            {k >= f(2) && <Big size={118} style={{ ...name, transformOrigin: 'left center', whiteSpace: 'nowrap' }}>{fin.name}</Big>}
            <div style={{ ...appear(3), fontFamily: fonts.sans, fontSize: 52, color: colors.text }}>{fin.line}</div>
            <div style={{ ...appear(4), alignSelf: 'flex-start', marginTop: 20, padding: '14px 30px', borderRadius: 40, background: colors.accent, color: '#11130c', fontFamily: fonts.sans, fontWeight: 700, fontSize: 38 }}>{fin.cta}</div>
          </AbsoluteFill>
        </AbsoluteFill>
      )}
      <Flash at={cut - 1} len={6} peak={0.5} />
    </AbsoluteFill>
  );
};

const duck = makeDuck(robotHypeCues, f);

export const RobotHype: React.FC = () => {
  const s = R.song;
  return (
    <AbsoluteFill style={{ background: colors.bg, color: colors.text, fontFamily: fonts.sans, overflow: 'hidden' }}>
      {R.hook.shots.map((shot, i) => (
        <Shot key={i} at={[R.hook.at[0] + i * 2, R.hook.at[0] + i * 2 + 2]}><HookShot shot={shot} /></Shot>
      ))}
      <Shot at={R.twin.at}><Twin /></Shot>
      <Measures />
      <Shot at={R.handle.at}><Handle /></Shot>
      <Shot at={R.truth.at}><Truth /></Shot>
      <Shot at={R.matrix.at}><Matrix /></Shot>
      <Shot at={R.finale.at}><Finale /></Shot>
      <Vignette />
      <Grain />
      <Audio
        src={staticFile(s.src)}
        trimBefore={Math.round(s.start * FPS)}
        volume={(fr) => s.volume * duck(fr) * interpolate(fr, [robotHypeFrames - 24, robotHypeFrames], [1, 0], clamp)}
      />
      {robotHypeCues.map((c, i) => <Effect key={i} cue={{ ...c, at: 0 }} frame={f(c.beat)} />)}
    </AbsoluteFill>
  );
};
