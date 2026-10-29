import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setOverwriteOutput(true);
Config.setCodec('h264');
Config.setCrf(18);
// WebGL (the 3D racket) needs a GPU-backed GL in headless Chrome.
Config.setChromiumOpenGlRenderer('angle');
// Three.js scenes are heavy; keep parallelism modest so frames don't time out.
Config.setConcurrency(4);
