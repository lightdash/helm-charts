#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { resolveConfig } from '../lib/config';
import { LightdashStack } from '../lib/lightdash-stack';

const app = new cdk.App();
const config = resolveConfig(app);

new LightdashStack(app, 'LightdashStack', {
  config,
  env: {
    account: config.account,
    region: config.region,
  },
  description: 'Self-hosted Lightdash on Amazon EKS',
  tags: {
    Application: 'lightdash',
    ManagedBy: 'aws-cdk',
  },
});

app.synth();
