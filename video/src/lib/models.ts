import { useEffect, useMemo, useState } from 'react';
import { cancelRender, continueRender, delayRender, staticFile } from 'remotion';
import * as THREE from 'three';

// Loads are cached per tab so scenes that share a model don't fetch it twice.
const cache = new Map<string, Promise<unknown>>();
const once = <T,>(key: string, load: () => Promise<T>) => {
  if (!cache.has(key)) cache.set(key, load());
  return cache.get(key) as Promise<T>;
};

/** Holds the frame until the asset is ready, so renders never show a blank model. */
function useAsset<T>(key: string, load: () => Promise<T>): T | null {
  const [value, setValue] = useState<T | null>(null);
  const [handle] = useState(() => delayRender(`load ${key}`, { timeoutInMilliseconds: 120_000 }));
  useEffect(() => {
    // Release the frame only after React has committed and the canvas has redrawn
    // (see useRedraw in Stage3D), otherwise the render captures an empty scene.
    once(key, load)
      .then((v) => { setValue(v); requestAnimationFrame(() => requestAnimationFrame(() => continueRender(handle))); })
      .catch(cancelRender);
  }, [key, handle]);
  return value;
}

type CadPart = { color: [number, number, number]; position: number[]; index: number[] };
type CadFile = { bounds: { min: number[]; max: number[] }; groups: Record<string, CadPart[]> };

export type CadGroup = { name: string; meshes: { geometry: THREE.BufferGeometry; color: THREE.Color }[]; center: THREE.Vector3 };

/** A STEP assembly converted by scripts/step-to-json.mjs (handle | robot). */
export const useCad = (name: 'handle' | 'robot') => {
  const file = useAsset(`cad:${name}`, () => fetch(staticFile(`models/${name}.json`)).then((r) => r.json() as Promise<CadFile>));
  return useMemo(() => {
    if (!file) return null;
    const groups: Record<string, CadGroup> = {};
    for (const [g, parts] of Object.entries(file.groups)) {
      const box = new THREE.Box3();
      const meshes = parts.map((p) => {
        const geometry = new THREE.BufferGeometry();
        geometry.setAttribute('position', new THREE.Float32BufferAttribute(p.position, 3));
        geometry.setIndex(p.index);
        geometry.computeVertexNormals();
        geometry.computeBoundingBox();
        box.union(geometry.boundingBox!);
        return { geometry, color: new THREE.Color(...p.color) };
      });
      groups[g] = { name: g, meshes, center: box.getCenter(new THREE.Vector3()) };
    }
    const b = file.bounds;
    const center = new THREE.Vector3(...b.min).add(new THREE.Vector3(...b.max)).multiplyScalar(0.5);
    return { groups, center, size: new THREE.Vector3(...b.max).sub(new THREE.Vector3(...b.min)) };
  }, [file]);
};
