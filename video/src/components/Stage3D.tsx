import { Bloom, EffectComposer, ToneMapping, Vignette } from '@react-three/postprocessing';
import { ThreeCanvas } from '@remotion/three';
import { useThree } from '@react-three/fiber';
import { ToneMappingMode } from 'postprocessing';
import React, { useEffect } from 'react';
import { useVideoConfig } from 'remotion';
import * as THREE from 'three';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';
import { colors } from '../config/brand';

/** Photo-studio HDR: softbox strips that draw long, clean highlights on glossy parts. */
function studioScene() {
  const scene = new THREE.Scene();
  const softbox = (w: number, h: number, pos: [number, number, number], intensity: number, color = '#ffffff') => {
    const m = new THREE.Mesh(
      new THREE.PlaneGeometry(w, h),
      new THREE.MeshBasicMaterial({ color: new THREE.Color(color).multiplyScalar(intensity), side: THREE.DoubleSide }),
    );
    m.position.set(...pos);
    m.lookAt(0, 0, 0);
    scene.add(m);
  };
  softbox(10, 1.4, [0, 7, 1], 3); // overhead strip
  softbox(1.6, 7, [-6, 1, 3], 5); // key, left
  softbox(1.0, 6, [6, 0.5, 2], 1.6); // fill, right
  softbox(1.2, 6, [3, 1, -6], 2.5); // back edge light
  softbox(8, 0.8, [0, -3, -6], 2.2, colors.accent); // lime kicker from behind/below
  return scene;
}

/** Image-based lighting: 'room' (neutral) or 'studio' (product-shot softboxes). */
const Environment: React.FC<{ kind: 'room' | 'studio'; intensity: number }> = ({ kind, intensity }) => {
  const { gl, scene } = useThree();
  useEffect(() => {
    const pmrem = new THREE.PMREMGenerator(gl);
    const env = pmrem.fromScene(kind === 'studio' ? studioScene() : new RoomEnvironment(), 0.04).texture;
    scene.environment = env;
    scene.environmentIntensity = intensity;
    return () => { env.dispose(); pmrem.dispose(); };
  }, [gl, scene, kind, intensity]);
  return null;
};

/**
 * ThreeCanvas only redraws when the frame number changes. Call this when content
 * appears later (async model loads) so it is actually drawn.
 */
export const useRedraw = (deps: unknown[]) => {
  const advance = useThree((s) => s.advance);
  useEffect(() => { advance(performance.now()); }, deps); // eslint-disable-line react-hooks/exhaustive-deps
};

/** Redraws after every commit of the canvas tree (e.g. a scene's CAD finished loading). */
const RedrawOnCommit: React.FC = () => {
  const advance = useThree((s) => s.advance);
  useEffect(() => { advance(performance.now()); });
  return null;
};

/** Camera driven from props each frame (Remotion renders frames out of order). */
const Camera: React.FC<{ position: [number, number, number]; target?: [number, number, number]; fov?: number }> = ({ position, target = [0, 0, 0], fov = 30 }) => {
  const { camera } = useThree();
  camera.position.set(...position);
  (camera as THREE.PerspectiveCamera).fov = fov;
  camera.lookAt(...target);
  camera.updateProjectionMatrix();
  return null;
};

type Props = {
  camera: [number, number, number];
  target?: [number, number, number];
  fov?: number;
  rim?: string; // colour of the back rim lights
  env?: 'room' | 'studio';
  envIntensity?: number;
  /** Hero quality: 2x supersampling, bloom, filmic tone mapping, vignette. Slower to render. */
  hero?: boolean;
  children: React.ReactNode;
};

/** Shared lighting rig: key, fill, lime rim. Every 3D scene uses this. */
export const Stage3D: React.FC<Props> = ({ camera, target, fov, rim = colors.accent, env = 'room', envIntensity = 0.6, hero, children }) => {
  const { width, height } = useVideoConfig();
  return (
    <ThreeCanvas
      width={width}
      height={height}
      dpr={hero ? 2 : 1}
      gl={{ antialias: !hero, alpha: true, toneMapping: hero ? THREE.NoToneMapping : THREE.ACESFilmicToneMapping }}
      style={{ position: 'absolute', inset: 0 }}
    >
      <Camera position={camera} target={target} fov={fov} />
      <Environment kind={env} intensity={envIntensity} />
      <ambientLight intensity={0.15} />
      <directionalLight position={[4, 6, 5]} intensity={hero ? 1.2 : 2.2} />
      <directionalLight position={[-5, 2, 3]} intensity={0.5} color="#cfd8ff" />
      <pointLight position={[-3, 2, -4]} intensity={60} distance={20} color={rim} />
      <pointLight position={[3, -1, -4]} intensity={30} distance={20} color={rim} />
      {children}
      {hero && (
        <EffectComposer multisampling={4}>
          <Bloom intensity={0.6} luminanceThreshold={0.85} luminanceSmoothing={0.15} mipmapBlur />
          <ToneMapping mode={ToneMappingMode.ACES_FILMIC} />
          <Vignette offset={0.3} darkness={0.55} />
        </EffectComposer>
      )}
      <RedrawOnCommit />
    </ThreeCanvas>
  );
};
