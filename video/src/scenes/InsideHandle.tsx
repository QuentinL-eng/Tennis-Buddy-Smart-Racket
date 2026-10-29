import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { Stage3D } from '../components/Stage3D';
import { Backdrop, Kicker, Title } from '../components/ui';
import { colors } from '../config/brand';
import { copy } from '../config/copy';
import { enter, ramp } from '../lib/anim';
import { useCad, type CadGroup } from '../lib/models';

// Timing (frames at 30 fps)
const EXPLODE = [40, 100] as const;
const LABEL_START = 105;
const LABEL_EVERY = 36;

const Part: React.FC<{ group?: CadGroup; offset?: [number, number, number]; glow?: number; ghost?: boolean }> = ({ group, offset = [0, 0, 0], glow = 0, ghost }) => {
  if (!group) return null;
  return (
    <group position={offset}>
      {group.meshes.map((m, i) => (
        <mesh key={i} geometry={m.geometry}>
          <meshStandardMaterial
            color={ghost ? '#2a2d24' : m.color}
            metalness={ghost ? 0.1 : 0.35}
            roughness={ghost ? 0.35 : 0.5}
            transparent={ghost}
            opacity={ghost ? 0.55 : 1}
            emissive={colors.accent}
            emissiveIntensity={glow * 0.9}
          />
        </mesh>
      ))}
    </group>
  );
};

// Exploded view of the real handle insert (Onshape STEP → public/models/handle.json).
export const InsideHandle: React.FC = () => {
  const frame = useCurrentFrame();
  const cad = useCad('handle');
  const parts = copy.insideHandle.parts;
  const explode = ramp(frame, ...EXPLODE);
  const active = Math.floor((frame - LABEL_START) / LABEL_EVERY);
  const glowFor = (name: string) => {
    const i = parts.findIndex((p) => p.part === name);
    if (i < 0 || i !== Math.min(active, parts.length - 1) || frame < LABEL_START) return 0;
    const local = frame - LABEL_START - i * LABEL_EVERY;
    return i === parts.length - 1 && local > LABEL_EVERY ? 0.35 : 0.5 + 0.5 * Math.sin(local / 4);
  };
  const turn = interpolate(frame, [0, 270], [-0.5, 0.35]);
  const lift = 22 * explode; // mm

  return (
    <Backdrop glow={0.1}>
      <Stage3D camera={[0, 3.2, 5.4]} target={[0, -0.1, 0]} fov={34}>
        {cad && (
          <group position={[-1.5, 0.05, 0]} rotation={[0, turn, 0]}>
            {/* mm → scene units; CAD length (Z) laid along screen X */}
            <group scale={0.036} rotation={[0, Math.PI / 2, 0]}>
              <group position={cad.center.clone().negate().toArray()}>
                <Part group={cad.groups.shell1} offset={[0, lift, 0]} ghost />
                <Part group={cad.groups.shell2} offset={[0, -lift, 0]} ghost />
                <Part group={cad.groups.screws} offset={[0, -lift, 0]} />
                <Part group={cad.groups.button} offset={[0, lift, 0]} />
                <Part group={cad.groups.board} glow={glowFor('board')} />
                <Part group={cad.groups.imu} offset={[0, 4 * explode, 0]} glow={glowFor('imu')} />
                <Part group={cad.groups.mic} offset={[0, 4 * explode, 0]} glow={glowFor('mic')} />
                <Part group={cad.groups.mcu} offset={[0, 4 * explode, 0]} glow={glowFor('mcu')} />
              </group>
            </group>
          </group>
        )}
      </Stage3D>
      <AbsoluteFill style={{ padding: '110px 120px', alignItems: 'flex-end' }}>
        <div style={{ width: 640, display: 'flex', flexDirection: 'column', gap: 14 }}>
          <Kicker style={enter(frame, 6)}>{copy.insideHandle.kicker}</Kicker>
          <Title size={64} style={enter(frame, 14)}>{copy.insideHandle.title}</Title>
          <div style={{ height: 30 }} />
          {parts.map((p, i) => {
            const on = frame >= LABEL_START + i * LABEL_EVERY;
            const current = i === Math.min(active, parts.length - 1);
            return (
              <div key={p.part} style={{ ...enter(frame, LABEL_START + i * LABEL_EVERY, 12), display: 'flex', gap: 20, alignItems: 'flex-start', padding: '16px 0', borderTop: `1px solid ${colors.track}`, opacity: on ? (current ? 1 : 0.55) : 0 }}>
                <div style={{ width: 14, height: 14, borderRadius: 7, marginTop: 14, background: current ? colors.accent : colors.track }} />
                <div>
                  <div style={{ fontSize: 40, fontWeight: 700 }}>{p.name}</div>
                  <div style={{ fontSize: 28, color: colors.muted, marginTop: 4 }}>{p.detail}</div>
                </div>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
