// Registry of CGI scenes. Add a scene: write the component, add it here,
// then reference its id in src/config/timeline.ts.
import { BuiltProof } from './BuiltProof';
import { ClubFinding } from './ClubFinding';
import { Devices } from './Devices';
import { Endcard } from './Endcard';
import { Evidence } from './Evidence';
import { GlassesPov } from './GlassesPov';
import { Hook } from './Hook';
import { Impact } from './Impact';
import { InsideHandle } from './InsideHandle';
import { MuseAgent } from './MuseAgent';
import { RacketReveal } from './RacketReveal';
import { RobotLab } from './RobotLab';
import { LiveTwin } from './LiveTwin';
import { RobotTwinScene } from './RobotTwinScene';
import { SamTrack } from './SamTrack';
import { Score } from './Score';
import { SwingFilmScene } from './SwingFilmScene';
import { Together } from './Together';
import { TwoModels } from './TwoModels';
import { WhatIf } from './WhatIf';

export const scenes = {
  robotTwin: RobotTwinScene,
  liveTwin: LiveTwin,
  twoModels: TwoModels,
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
  clubFinding: ClubFinding,
  evidence: Evidence,
  museAgent: MuseAgent,
  samTrack: SamTrack,
  glassesPov: GlassesPov,
  builtProof: BuiltProof,
  swingFilm: SwingFilmScene,
};

export type SceneId = keyof typeof scenes;
