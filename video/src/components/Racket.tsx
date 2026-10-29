import type { ThreeElements } from '@react-three/fiber';
import React, { useMemo } from 'react';
import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { colors } from '../config/brand';
import { carbonWeave, gripWrap } from '../lib/textures';

export const RACKET_LENGTH = 3; // scene units, butt to tip

// A generic, unbranded racket built from real dimensions (metres, measured from the butt):
// 27" (0.685 m) long, ~100 sq in head, 23 mm deep beam, 16x19 string pattern.
// The frame is one continuous tube swept along its centreline, like a moulded
// carbon frame, rather than a flat cut-out.
const D = {
  length: 0.685,
  // head hoop centreline: superellipse centred at headY
  headA: 0.1245, // half-width to beam centre (outer width ~26 cm)
  headB: 0.164, // half-length to beam centre (outer length ~34 cm)
  headY: 0.516,
  n: 2.3, // >2 = slightly squarer than an ellipse, like a modern head
  beamW: 0.0065, // half the face width (13 mm)
  beamD: 0.0115, // half the beam depth (23 mm)
  groove: 0.18, // stringing groove around the outside of the hoop
  // throat: arms split from the shaft and flow into the hoop sides
  arm: [[0, 0.246], [0.008, 0.268], [0.02, 0.293], [0.037, 0.321], [0.058, 0.35]] as [number, number][],
  armJoin: [-0.9, -0.76, -0.6], // hoop angles the arm blends into
  shaftTop: 0.262, // the arms split ~5 cm above the grip
  mains: 16,
  crosses: 19,
  mainGap: 0.0128,
  crossGap: 0.0158,
  string: 0.00065, // radius (1.3 mm gauge)
};

const sgnPow = (v: number, p: number) => Math.sign(v) * Math.abs(v) ** p;
const hoop = (t: number, grow = 0) =>
  new THREE.Vector3((D.headA + grow) * sgnPow(Math.cos(t), 2 / D.n), D.headY + (D.headB + grow) * sgnPow(Math.sin(t), 2 / D.n), 0);
/** Half-span of the hoop superellipse (grown by `grow`) at offset u along the other axis. */
const halfSpan = (along: number, across: number, u: number) => across * Math.max(0, 1 - Math.abs(u / along) ** D.n) ** (1 / D.n);

/**
 * Sweep a rounded, slightly boxy cross-section along a centreline in the XY plane.
 * Profile angle 0 points to the right of travel (outward on a counter-clockwise loop).
 */
function sweep(path: THREE.Vector3[], closed: boolean, opts: { width?: (s: number) => number; groove?: number } = {}) {
  const R = 48, m = 2.6;
  const width = opts.width ?? (() => D.beamW);
  const groove = opts.groove ?? 0;
  const profile = (th: number, w: number) => {
    const g = 1 - groove * Math.exp(-((th / 0.3) ** 2));
    return [w * sgnPow(Math.cos(th), 2 / m) * g, D.beamD * sgnPow(Math.sin(th), 2 / m)];
  };
  const count = path.length, pos: number[] = [], nor: number[] = [], uv: number[] = [], idx: number[] = [];
  let travelled = 0;
  for (let i = 0; i < count; i++) {
    const prev = path[closed ? (i - 1 + count) % count : Math.max(0, i - 1)];
    const next = path[closed ? (i + 1) % count : Math.min(count - 1, i + 1)];
    const T = next.clone().sub(prev).normalize();
    const N = new THREE.Vector3(T.y, -T.x, 0);
    if (i) travelled += path[i].distanceTo(path[i - 1]);
    const w = width(i / (count - 1));
    for (let j = 0; j <= R; j++) {
      const th = -Math.PI + (2 * Math.PI * j) / R;
      const [u, v] = profile(th, w);
      const [u2, v2] = profile(th + 1e-3, w);
      // outward normal of the profile, then into 3D
      const n = new THREE.Vector2(v2 - v, -(u2 - u)).normalize();
      const p = path[i];
      pos.push(p.x + N.x * u, p.y + N.y * u, v);
      const n3 = N.clone().multiplyScalar(n.x).add(new THREE.Vector3(0, 0, n.y)).normalize();
      nor.push(n3.x, n3.y, n3.z);
      uv.push(travelled * 60, j / R);
    }
  }
  const rings = closed ? count : count - 1;
  for (let i = 0; i < rings; i++) {
    const a = i * (R + 1), b = ((i + 1) % count) * (R + 1);
    for (let j = 0; j < R; j++) idx.push(a + j, b + j, a + j + 1, a + j + 1, b + j, b + j + 1);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('normal', new THREE.Float32BufferAttribute(nor, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  g.setIndex(idx);
  return g;
}

/** Hoop (its bottom is the bridge), two throat arms and the shaft, as one merged mesh. */
function frameGeometry() {
  const N = 720;
  const hoopPath = Array.from({ length: N }, (_, i) => hoop((2 * Math.PI * i) / N));
  const hoopGeo = sweep(hoopPath, true, { groove: D.groove });

  // Each arm: up from inside the shaft, then along the hoop so it blends in tangentially.
  const arm = (side: 1 | -1) => {
    const pts = [
      ...D.arm.map(([x, y]) => new THREE.Vector3(side * x, y, 0)),
      ...D.armJoin.map((t) => hoop(side > 0 ? t : Math.PI - t)),
    ];
    const path = new THREE.CatmullRomCurve3(pts, false, 'centripetal').getSpacedPoints(160);
    return sweep(path, false, { width: (s) => D.beamW * (1.15 - 0.15 * s) }); // a touch thicker at the split
  };

  const shaftPath = Array.from({ length: 30 }, (_, i) => new THREE.Vector3(0, 0.17 + ((D.shaftTop - 0.17) * i) / 29, 0));
  const shaft = sweep(shaftPath, false, { width: () => 0.0115 });

  return mergeGeometries([hoopGeo, arm(1), arm(-1), shaft]);
}

/** 16x19 string bed, mains and crosses woven over/under each other, ends buried in the beam. */
function stringGeometry() {
  const a = D.headA - 0.002, b = D.headB - 0.002;
  const amp = D.string * 0.9;
  const x0 = -((D.mains - 1) / 2) * D.mainGap;
  const y0 = D.headY - ((D.crosses - 1) / 2) * D.crossGap;
  const tubes: THREE.BufferGeometry[] = [];
  const tube = (pts: THREE.Vector3[]) => tubes.push(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), pts.length * 3, D.string, 6));

  for (let i = 0; i < D.mains; i++) {
    const x = x0 + i * D.mainGap, h = halfSpan(a, b, x), sign = i % 2 ? -1 : 1;
    const pts = [];
    for (let k = 0; k <= 48; k++) {
      const y = D.headY - h + (2 * h * k) / 48;
      pts.push(new THREE.Vector3(x, y, sign * amp * Math.cos((Math.PI * (y - y0)) / D.crossGap)));
    }
    tube(pts);
  }
  for (let j = 0; j < D.crosses; j++) {
    const y = y0 + j * D.crossGap, w = halfSpan(b, a, y - D.headY), sign = j % 2 ? -1 : 1;
    if (!w) continue;
    const pts = [];
    for (let k = 0; k <= 40; k++) {
      const x = -w + (2 * w * k) / 40;
      pts.push(new THREE.Vector3(x, y, -sign * amp * Math.cos((Math.PI * (x - x0)) / D.mainGap)));
    }
    tube(pts);
  }
  return mergeGeometries(tubes);
}

type Props = ThreeElements['group'] & {
  /** 0..1: the lime ring on the butt cap (where the sensor insert lives). */
  glow?: number;
};

/**
 * Head up (+Y), strings facing the camera (+Z), centred on the origin,
 * RACKET_LENGTH units long. Rotate/position the group to animate.
 */
export const Racket: React.FC<Props> = ({ glow = 0, ...props }) => {
  const parts = useMemo(() => {
    const weave = carbonWeave();
    weave.repeat.set(3, 12); // sweep UVs: u = 60 per metre along the beam, v = once around it
    const wrap = gripWrap();
    wrap.repeat.set(1, 9);
    return {
      frame: frameGeometry(),
      strings: stringGeometry(),
      frameMat: new THREE.MeshPhysicalMaterial({ color: '#202328', metalness: 0.25, roughness: 0.38, clearcoat: 1, clearcoatRoughness: 0.05, bumpMap: weave, bumpScale: 0.2 }),
      bumperMat: new THREE.MeshPhysicalMaterial({ color: '#0d0d0e', roughness: 0.75 }),
      stringMat: new THREE.MeshPhysicalMaterial({ color: '#ecebe2', roughness: 0.32, clearcoat: 0.6, clearcoatRoughness: 0.2 }),
      gripMat: new THREE.MeshPhysicalMaterial({ color: '#f1f0ea', roughness: 0.8, bumpMap: wrap, bumpScale: 2, sheen: 0.4, sheenRoughness: 0.6 }),
      capMat: new THREE.MeshPhysicalMaterial({ color: '#141518', metalness: 0.2, roughness: 0.35, clearcoat: 1, clearcoatRoughness: 0.08 }),
    };
  }, []);
  const s = RACKET_LENGTH / D.length;
  const oct = Math.PI / 8; // turn the octagon so a bevel faces the strings

  return (
    <group {...props}>
      <group scale={s} position={[0, -(D.length / 2) * s, 0]}>
        <mesh geometry={parts.frame} material={parts.frameMat} />
        <mesh geometry={parts.strings} material={parts.stringMat} />
        {/* handle: overgrip, finishing tape, throat collar, butt cap */}
        <mesh position={[0, 0.107, 0]} rotation={[0, oct, 0]} material={parts.gripMat}>
          <cylinderGeometry args={[0.0168, 0.0172, 0.19, 8, 1]} />
        </mesh>
        <mesh position={[0, 0.2, 0]} rotation={[0, oct, 0]} material={parts.bumperMat}>
          <cylinderGeometry args={[0.0171, 0.0171, 0.008, 8, 1]} />
        </mesh>
        <mesh position={[0, 0.21, 0]} rotation={[0, oct, 0]} material={parts.capMat}>
          <cylinderGeometry args={[0.0128, 0.0168, 0.014, 8, 1]} />
        </mesh>
        <mesh position={[0, 0.006, 0]} rotation={[0, oct, 0]} material={parts.capMat}>
          <cylinderGeometry args={[0.0186, 0.0186, 0.012, 8, 1]} />
        </mesh>
        <mesh position={[0, 0.0125, 0]} rotation={[Math.PI / 2, 0, 0]}>
          <torusGeometry args={[0.0176, 0.0011, 8, 64]} />
          <meshStandardMaterial color={colors.accent} emissive={colors.accent} emissiveIntensity={0.3 + glow * 4} toneMapped={false} />
        </mesh>
      </group>
    </group>
  );
};
