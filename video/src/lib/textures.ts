// Small procedural textures (canvas-drawn, so no image assets and fully deterministic).
import * as THREE from 'three';

const canvasTexture = (w: number, h: number, draw: (ctx: CanvasRenderingContext2D) => void) => {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  draw(c.getContext('2d')!);
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.anisotropy = 8;
  return t;
};

/** 2x2 twill carbon weave, used as a bump map on the frame. */
export const carbonWeave = () =>
  canvasTexture(64, 64, (ctx) => {
    for (let y = 0; y < 8; y++)
      for (let x = 0; x < 8; x++) {
        const over = ((x + y) >> 1) % 2 === 0;
        const g = ctx.createLinearGradient(x * 8, y * 8, x * 8 + (over ? 8 : 0), y * 8 + (over ? 0 : 8));
        g.addColorStop(0, '#6a6a6a');
        g.addColorStop(0.5, over ? '#d0d0d0' : '#b0b0b0');
        g.addColorStop(1, '#6a6a6a');
        ctx.fillStyle = g;
        ctx.fillRect(x * 8, y * 8, 8, 8);
      }
  });

/** Overgrip wrap: one slanted overlap groove per tile; repeat along the handle for the spiral. */
export const gripWrap = () =>
  canvasTexture(256, 64, (ctx) => {
    ctx.fillStyle = '#d8d8d8';
    ctx.fillRect(0, 0, 256, 64);
    // fine perforation texture
    for (let i = 0; i < 900; i++) {
      const x = (i * 97) % 256, y = (i * 53) % 64;
      ctx.fillStyle = '#c4c4c4';
      ctx.fillRect(x, y, 1.5, 1.5);
    }
    // the overlap edge, slanting one full turn across the tile
    for (const dx of [-256, 0, 256]) {
      ctx.strokeStyle = '#5a5a5a';
      ctx.lineWidth = 5;
      ctx.beginPath();
      ctx.moveTo(dx, 64);
      ctx.lineTo(dx + 256, 0);
      ctx.stroke();
      ctx.strokeStyle = '#f2f2f2';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(dx + 4, 64);
      ctx.lineTo(dx + 260, 0);
      ctx.stroke();
    }
  });
