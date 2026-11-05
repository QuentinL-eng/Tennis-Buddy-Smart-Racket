import React from 'react';
import { RobotTwin } from '../hype/RobotTwin';

// A wrapper so the registry doesn't need RobotTwin while it loads: that file imports Timeline, which imports the registry.
export const RobotTwinScene: React.FC = () => <RobotTwin />;
