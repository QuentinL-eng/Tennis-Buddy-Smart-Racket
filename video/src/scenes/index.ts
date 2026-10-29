// Registry of CGI scenes. Add a scene: write the component, add it here,
// then reference its id in src/config/timeline.ts.
import { Devices } from './Devices';
import { Endcard } from './Endcard';
import { Hook } from './Hook';
import { Impact } from './Impact';
import { InsideHandle } from './InsideHandle';
import { RacketReveal } from './RacketReveal';
import { RobotLab } from './RobotLab';
import { Score } from './Score';
import { Together } from './Together';
import { WhatIf } from './WhatIf';

export const scenes = {
  hook: Hook,
  racketReveal: RacketReveal,
  insideHandle: InsideHandle,
  impact: Impact,
  robotLab: RobotLab,
  devices: Devices,
  score: Score,
  whatIf: WhatIf,
  together: Together,
  endcard: Endcard,
};

export type SceneId = keyof typeof scenes;
