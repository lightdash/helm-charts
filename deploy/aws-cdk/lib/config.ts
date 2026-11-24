import { Construct } from 'constructs';

/**
 * Every input to the deployment, resolved from CDK context.
 *
 * Context is used rather than environment variables so that `cdk synth`,
 * `cdk diff` and `cdk deploy` all see the same values, and so that a team can
 * commit its own defaults to cdk.context.json without touching this file.
 */
export interface LightdashConfig {
  /** Deployment region. Falls back to the CLI or profile region. */
  readonly region?: string;
  /** Account to deploy into. Falls back to the CLI credentials. */
  readonly account?: string;

  /**
   * Public hostname for the instance, for example lightdash.example.com.
   *
   * When unset the load balancer answers on any host and SITE_URL is left
   * empty, which is enough to reach the login page but leaves emailed links
   * pointing at the wrong origin. See the README for the two-pass workflow.
   */
  readonly hostname?: string;
  /** ACM certificate for the load balancer. Requires hostname. */
  readonly certificateArn?: string;
  /**
   * Accepts a load balancer that serves plain HTTP to the internet, which is
   * what happens with no certificate. Required rather than assumed, because
   * logins and session cookies would otherwise cross the internet in clear
   * text without the operator ever choosing that.
   */
  readonly allowInsecureHttp: boolean;

  readonly vpcCidr: string;
  /**
   * One NAT gateway is the default because two is the largest avoidable cost
   * in this stack. Raise to the AZ count for production.
   */
  readonly natGateways: number;
  readonly maxAzs: number;

  readonly kubernetesVersion: string;
  readonly nodeInstanceType: string;
  readonly nodeDiskSizeGb: number;
  readonly nodeMinSize: number;
  readonly nodeMaxSize: number;
  readonly nodeDesiredSize: number;

  readonly dbInstanceType: string;
  readonly dbAllocatedStorageGb: number;
  readonly dbMaxAllocatedStorageGb: number;
  readonly dbBackupRetentionDays: number;
  /**
   * Turns on RDS deletion protection. Off by default, because it makes
   * `cdk destroy` fail at the database until a redeploy turns it off again,
   * including the final snapshot that retainData asks for. It belongs here
   * rather than in the console, where the next deploy would revert it.
   */
  readonly dbDeletionProtection: boolean;
  /**
   * Engine version. The major family on its own, for example 16, which RDS
   * resolves to the latest minor it supports. A full version such as 16.14
   * pins the minor at create time, but RDS removes old minors as they age, so
   * a pinned default would eventually stop being deployable at all. Minor
   * upgrades are applied in the maintenance window either way.
   */
  readonly postgresVersion: string;
  /** Major version family the engine version belongs to, for example 16. */
  readonly postgresMajorVersion: string;

  readonly namespace: string;
  readonly releaseName: string;
  /**
   * Version of the upstream lightdash chart to install. Pinned rather than
   * floating so that a redeploy is reproducible.
   */
  readonly chartVersion: string;
  readonly chartRepository: string;

  /**
   * When true, `cdk destroy` takes a final database snapshot and keeps the
   * bucket and the secrets. Off by default because the primary audience is
   * evaluating, and retained storage keeps billing after the operator believes
   * they have torn everything down.
   */
  readonly retainData: boolean;

  /** Principal granted cluster-admin, for example an SSO role ARN. */
  readonly adminRoleArn?: string;
}

const DEFAULTS = {
  allowInsecureHttp: false,
  vpcCidr: '10.0.0.0/16',
  natGateways: 1,
  maxAzs: 2,
  kubernetesVersion: '1.31',
  nodeInstanceType: 't3.large',
  nodeDiskSizeGb: 30,
  nodeMinSize: 2,
  nodeMaxSize: 4,
  nodeDesiredSize: 2,
  dbInstanceType: 't4g.micro',
  dbAllocatedStorageGb: 20,
  dbMaxAllocatedStorageGb: 100,
  dbBackupRetentionDays: 7,
  dbDeletionProtection: false,
  postgresVersion: '16',
  postgresMajorVersion: '16',
  namespace: 'lightdash',
  releaseName: 'lightdash',
  chartVersion: '2.10.241',
  chartRepository: 'https://lightdash.github.io/helm-charts',
  retainData: false,
} as const;

function str(scope: Construct, key: string, fallback: string): string {
  const value = scope.node.tryGetContext(key);
  return value === undefined || value === '' ? fallback : String(value);
}

function optionalStr(scope: Construct, key: string): string | undefined {
  const value = scope.node.tryGetContext(key);
  return value === undefined || value === '' ? undefined : String(value);
}

function num(scope: Construct, key: string, fallback: number): number {
  const value = scope.node.tryGetContext(key);
  if (value === undefined || value === '') {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Context value ${key} must be a number, got "${value}"`);
  }
  return parsed;
}

function bool(scope: Construct, key: string, fallback: boolean): boolean {
  const value = scope.node.tryGetContext(key);
  if (value === undefined || value === '') {
    return fallback;
  }
  // Context arriving from -c is always a string, so compare textually.
  return value === true || String(value).toLowerCase() === 'true';
}

export function resolveConfig(scope: Construct): LightdashConfig {
  const config: LightdashConfig = {
    region: optionalStr(scope, 'region') ?? process.env.CDK_DEFAULT_REGION,
    account: optionalStr(scope, 'account') ?? process.env.CDK_DEFAULT_ACCOUNT,

    hostname: optionalStr(scope, 'hostname'),
    certificateArn: optionalStr(scope, 'certificateArn'),
    allowInsecureHttp: bool(scope, 'allowInsecureHttp', DEFAULTS.allowInsecureHttp),

    vpcCidr: str(scope, 'vpcCidr', DEFAULTS.vpcCidr),
    natGateways: num(scope, 'natGateways', DEFAULTS.natGateways),
    maxAzs: num(scope, 'maxAzs', DEFAULTS.maxAzs),

    kubernetesVersion: str(scope, 'kubernetesVersion', DEFAULTS.kubernetesVersion),
    nodeInstanceType: str(scope, 'nodeInstanceType', DEFAULTS.nodeInstanceType),
    nodeDiskSizeGb: num(scope, 'nodeDiskSizeGb', DEFAULTS.nodeDiskSizeGb),
    nodeMinSize: num(scope, 'nodeMinSize', DEFAULTS.nodeMinSize),
    nodeMaxSize: num(scope, 'nodeMaxSize', DEFAULTS.nodeMaxSize),
    nodeDesiredSize: num(scope, 'nodeDesiredSize', DEFAULTS.nodeDesiredSize),

    dbInstanceType: str(scope, 'dbInstanceType', DEFAULTS.dbInstanceType),
    dbAllocatedStorageGb: num(scope, 'dbAllocatedStorageGb', DEFAULTS.dbAllocatedStorageGb),
    dbMaxAllocatedStorageGb: num(
      scope,
      'dbMaxAllocatedStorageGb',
      DEFAULTS.dbMaxAllocatedStorageGb,
    ),
    dbBackupRetentionDays: num(scope, 'dbBackupRetentionDays', DEFAULTS.dbBackupRetentionDays),
    dbDeletionProtection: bool(scope, 'dbDeletionProtection', DEFAULTS.dbDeletionProtection),
    postgresVersion: str(scope, 'postgresVersion', DEFAULTS.postgresVersion),
    postgresMajorVersion: str(scope, 'postgresMajorVersion', DEFAULTS.postgresMajorVersion),

    namespace: str(scope, 'namespace', DEFAULTS.namespace),
    releaseName: str(scope, 'releaseName', DEFAULTS.releaseName),
    chartVersion: str(scope, 'chartVersion', DEFAULTS.chartVersion),
    chartRepository: str(scope, 'chartRepository', DEFAULTS.chartRepository),

    retainData: bool(scope, 'retainData', DEFAULTS.retainData),
    adminRoleArn: optionalStr(scope, 'adminRoleArn'),
  };

  validate(config);
  return config;
}

/**
 * Rejects at synth what the services would otherwise reject mid-deploy, after
 * a cluster has been created and paid for.
 */
function validate(config: LightdashConfig): void {
  // Sizes and counts are integers everywhere they are consumed, and Number()
  // happily returns 1.5, which arrives at CloudFormation as an invalid
  // property rather than a config error.
  for (const [key, value, minimum] of [
    ['natGateways', config.natGateways, 1],
    ['maxAzs', config.maxAzs, 2],
    ['nodeDiskSizeGb', config.nodeDiskSizeGb, 20],
    ['nodeMinSize', config.nodeMinSize, 1],
    ['nodeMaxSize', config.nodeMaxSize, 1],
    ['nodeDesiredSize', config.nodeDesiredSize, 1],
    ['dbAllocatedStorageGb', config.dbAllocatedStorageGb, 20],
    ['dbMaxAllocatedStorageGb', config.dbMaxAllocatedStorageGb, 20],
    ['dbBackupRetentionDays', config.dbBackupRetentionDays, 0],
  ] as const) {
    if (!Number.isInteger(value)) {
      throw new Error(`${key} must be a whole number, got ${value}`);
    }
    if (value < minimum) {
      throw new Error(`${key} must be at least ${minimum}, got ${value}`);
    }
  }

  if (config.certificateArn && !config.hostname) {
    throw new Error('certificateArn requires hostname, since the certificate must match a host');
  }
  if (!config.certificateArn && !config.allowInsecureHttp) {
    throw new Error(
      'Without certificateArn the load balancer is internet-facing and serves plain HTTP, ' +
        'so logins cross the internet in clear text. Pass -c hostname and -c certificateArn ' +
        'for TLS, or -c allowInsecureHttp=true to accept that for an evaluation.',
    );
  }
  if (config.nodeDesiredSize < config.nodeMinSize || config.nodeDesiredSize > config.nodeMaxSize) {
    throw new Error('nodeDesiredSize must fall between nodeMinSize and nodeMaxSize');
  }
  if (config.dbMaxAllocatedStorageGb < config.dbAllocatedStorageGb) {
    throw new Error(
      'dbMaxAllocatedStorageGb must be at least dbAllocatedStorageGb, since RDS storage ' +
        'autoscaling only grows',
    );
  }
  if (config.dbBackupRetentionDays > 35) {
    throw new Error('dbBackupRetentionDays cannot exceed 35, the RDS maximum');
  }
  const major = config.postgresMajorVersion;
  if (config.postgresVersion !== major && !config.postgresVersion.startsWith(`${major}.`)) {
    throw new Error(
      `postgresVersion ${config.postgresVersion} is not in major family ${major}`,
    );
  }
}
