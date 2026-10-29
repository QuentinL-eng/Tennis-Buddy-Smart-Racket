import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { Stage3D } from '../components/Stage3D';
import { Backdrop, Kicker, Title } from '../components/ui';
import { colors } from '../config/brand';
import { copy } from '../config/copy';
import { enter, lerp, ramp } from '../lib/anim';
import { useCad, type CadGroup } from '../lib/models';
import type * as THREE from 'three';

// CAD is in mm, Z up (Onshape). J1 (base yaw) = centre of the turret on top of the base.
const J1: [number, number] = [56, 22];
const TURRET_TOP = 244;
// J2 (shoulder pitch): centre of the round boss at the bottom of arm_2, axis along Y.
const J2: [number, number, number] = [-44, 22, 438];
const SCALE = 0.0036;
const CONTACTS = [76, 171]; // frames where the strings meet the ball (beats 4 and 9 at 95 BPM)
const HEAD: [number, number, number] = [-545, -430, 871]; // string-bed centre at swing angle 0
const BACK = -0.6, THROUGH = 0.6;

const smooth = (x: number) => x * x * (3 - 2 * x);
/** Slow wind-up, fast swing through contact, slow recovery. */
const swingAngle = (f: number) => {
  for (let k = 0; k < CONTACTS.length; k++) {
    const c = CONTACTS[k];
    const prevEnd = k === 0 ? 0 : CONTACTS[k - 1] + 20;
    if (f < c - 20) return k === 0 ? lerp(0, BACK, smooth(Math.min(1, f / (c - 20)))) : lerp(THROUGH, BACK, smooth((f - prevEnd) / (c - 20 - prevEnd)));
    if (f <= c + 20) return BACK + (THROUGH - BACK) * (0.5 + 0.5 * Math.tanh((f - c) / 5) / Math.tanh(4));
  }
  return THROUGH;
};

const Group: React.FC<{ group?: CadGroup; glow?: number }> = ({ group, glow = 0 }) => (
  <>
    {group?.meshes.map((m, i) => (
      <mesh key={i} geometry={m.geometry}>
        <meshStandardMaterial color={m.color} metalness={0.25} roughness={0.45} emissive={colors.accent} emissiveIntensity={glow} />
      </mesh>
    ))}
  </>
);

/**
 * STAND-IN for link 1 (J1 → J2), which is missing from the STEP export: a column on
 * the J1 turret plus the J2 hub that arm_2 pivots on. Used only while the export has
 * no `_arm_1` mesh; re-export with it and this disappears automatically.
 */
const Shoulder: React.FC<{ color?: THREE.Color }> = ({ color }) => {
  const mat = <meshStandardMaterial color={color ?? '#e8e8e4'} metalness={0.25} roughness={0.45} />;
  const columnH = J2[2] - TURRET_TOP;
  return (
    <>
      {/* column rising from the turret (cylinder axis Y → CAD Z) */}
      <mesh position={[J1[0], J1[1], TURRET_TOP + columnH / 2]} rotation={[Math.PI / 2, 0, 0]}>
        <cylinderGeometry args={[82, 88, columnH, 64]} />
        {mat}
      </mesh>
      {/* dome cap (hemisphere's +Y turned to CAD +Z) */}
      <mesh position={[J1[0], J1[1], J2[2]]} rotation={[Math.PI / 2, 0, 0]} scale={[82, 40, 82]}>
        <sphereGeometry args={[1, 48, 24, 0, Math.PI * 2, 0, Math.PI / 2]} />
        {mat}
      </mesh>
      {/* J2 hub joining the column to the bottom of arm_2 (axis along CAD Y) */}
      <mesh position={J2}>
        <cylinderGeometry args={[70, 70, 150, 64]} />
        {mat}
      </mesh>
      <mesh position={[(J1[0] + J2[0]) / 2, J2[1], J2[2] - 20]}>
        <boxGeometry args={[J1[0] - J2[0], 150, 100]} />
        {mat}
      </mesh>
    </>
  );
};

// The Epson C8 test rig from the Onshape assembly, swinging the racket into balls.
export const RobotLab: React.FC = () => {
  const frame = useCurrentFrame();
  const cad = useCad('robot');
  const angle = swingAngle(frame);
  const orbit = interpolate(frame, [0, 240], [-0.9, -0.35]);
  const cam: [number, number, number] = [Math.sin(orbit) * 7.4, 1.6, Math.cos(orbit) * 7.4];

  // Ball in CAD space: in from the string side (-X), back out after contact.
  const c = CONTACTS.find((x) => frame < x + 30) ?? CONTACTS[CONTACTS.length - 1];
  const inT = ramp(frame, c - 22, c, (x) => x);
  const outT = ramp(frame, c, c + 26, (x) => x);
  const ball: [number, number, number] = frame < c
    ? [lerp(-1900, HEAD[0] - 40, inT), lerp(HEAD[1] - 300, HEAD[1], inT), lerp(HEAD[2] + 160, HEAD[2], inT)]
    : [lerp(HEAD[0] - 40, -2200, outT), lerp(HEAD[1], HEAD[1] - 900, outT), lerp(HEAD[2], HEAD[2] + 500, outT)];
  const flash = Math.max(0, 1 - Math.abs(frame - c) / 8);

  return (
    <Backdrop glow={0.08}>
      <Stage3D camera={cam} target={[-0.2, 0.4, 0]} fov={36}>
        {cad && (
          <group position={[-0.9, 0, 0]}>
            <gridHelper args={[14, 28, colors.track, '#1a1d14']} position={[0, (-28 - cad.center.z) * SCALE, 0]} />
            <group scale={SCALE} rotation={[-Math.PI / 2, 0, 0]}>
              <group position={cad.center.clone().negate().toArray()}>
                <Group group={cad.groups.base} />
                <Group group={cad.groups.uno} />
                <Group group={cad.groups.rig} />
                <group position={[J1[0], J1[1], 0]} rotation={[0, 0, angle]}>
                  <group position={[-J1[0], -J1[1], 0]}>
                    {cad.groups.shoulder ? <Group group={cad.groups.shoulder} /> : <Shoulder color={cad.groups.base?.meshes[0].color} />}
                    <Group group={cad.groups.swing} />
                    <Group group={cad.groups.racket} glow={flash * 0.8} />
                  </group>
                </group>
                {frame > c - 24 && (
                  <mesh position={ball}>
                    <sphereGeometry args={[34, 32, 32]} />
                    <meshStandardMaterial color="#D9EE3F" roughness={0.9} emissive="#D9EE3F" emissiveIntensity={0.15} />
                  </mesh>
                )}
              </group>
            </group>
          </group>
        )}
      </Stage3D>
      <AbsoluteFill style={{ padding: '110px 120px', alignItems: 'flex-end' }}>
        <div style={{ width: 620, display: 'flex', flexDirection: 'column', gap: 14 }}>
          <Kicker style={enter(frame, 6)}>{copy.robotLab.kicker}</Kicker>
          <Title size={62} style={enter(frame, 14)}>{copy.robotLab.title}</Title>
          <div style={{ height: 24 }} />
          {copy.robotLab.bullets.map((b, i) => (
            <div key={b} style={{ ...enter(frame, 40 + i * 22), fontSize: 34, display: 'flex', gap: 16, alignItems: 'center', padding: '10px 0' }}>
              <div style={{ width: 10, height: 10, borderRadius: 5, background: colors.accent }} />
              {b}
            </div>
          ))}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
