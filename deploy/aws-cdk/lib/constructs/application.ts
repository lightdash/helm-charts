import { Duration } from 'aws-cdk-lib';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { LightdashConfig } from '../config';
import {
  APPLICATION_SECRET_NAME,
  DATABASE_PASSWORD_KEY,
  DATABASE_SECRET_NAME,
} from './secret-sync';

export interface ApplicationProps {
  readonly config: LightdashConfig;
  readonly cluster: eks.Cluster;
  readonly namespaceManifest: eks.KubernetesManifest;
  readonly bucket: s3.IBucket;
  readonly database: rds.DatabaseInstance;
  readonly databaseName: string;
  readonly databaseUser: string;
  readonly region: string;
  /** Applied before the release, so the secrets exist when pods start. */
  readonly dependencies: eks.KubernetesManifest[];
}

const SERVICE_ACCOUNT_NAME = 'lightdash';
/** Readiness path the chart already uses, reused for the load balancer. */
const HEALTH_CHECK_PATH = '/api/v1/health';

/**
 * Installs the upstream lightdash chart, unmodified, against the provisioned
 * AWS resources.
 *
 * The chart is pulled from the published repository by version. It is never
 * vendored or patched, so this deployment path stays valid as the chart is
 * released independently.
 */
export class Application extends Construct {
  public readonly serviceAccount: eks.ServiceAccount;
  public readonly release: eks.HelmChart;

  constructor(scope: Construct, id: string, props: ApplicationProps) {
    super(scope, id);

    const {
      config,
      cluster,
      namespaceManifest,
      bucket,
      database,
      databaseName,
      databaseUser,
      region,
      dependencies,
    } = props;

    // IRSA, so the pods reach S3 with a scoped role instead of access keys
    // held in a Secret. Lightdash omits explicit credentials when
    // S3_ACCESS_KEY is unset and falls back to the AWS SDK chain, which picks
    // up the projected web identity token.
    this.serviceAccount = cluster.addServiceAccount('ServiceAccount', {
      name: SERVICE_ACCOUNT_NAME,
      namespace: config.namespace,
    });
    this.serviceAccount.node.addDependency(namespaceManifest);
    bucket.grantReadWrite(this.serviceAccount);

    const useTls = Boolean(config.certificateArn);
    const siteUrl = config.hostname
      ? `${useTls ? 'https' : 'http'}://${config.hostname}`
      : '';

    // Encrypts the database connection without verifying the server
    // certificate. RDS PostgreSQL 15 and later default rds.force_ssl to 1, so
    // an unencrypted connection is refused outright and this cannot be omitted.
    //
    // no-verify rather than require, which is not the libpq meaning of either.
    // Lightdash connects through node-postgres, so require ends up in Node's
    // TLS defaults and the chain is checked against the image's trust store,
    // which has no Amazon RDS root. The result is that every start dies with
    // "self-signed certificate in certificate chain" before the migrations run.
    // See the README for moving to verify-full with the RDS CA bundle, which
    // the chart supports through ssl.enabled.
    const sslEnv = [{ name: 'PGSSLMODE', value: 'no-verify' }];

    const values = {
      // The chart's bundled PostgreSQL is replaced by RDS.
      postgresql: { enabled: false },
      externalDatabase: {
        host: database.instanceEndpoint.hostname,
        port: database.instanceEndpoint.port,
        user: databaseUser,
        database: databaseName,
        existingSecret: DATABASE_SECRET_NAME,
        secretKeys: { passwordKey: DATABASE_PASSWORD_KEY },
      },

      // envFrom on every pod. Supplies LIGHTDASH_SECRET, which otherwise
      // defaults to the literal "changeme" from the chart's values.
      existingSecret: APPLICATION_SECRET_NAME,

      // existingSecret already wins in envFrom, but .Values.secrets separately
      // decides whether the chart creates a Secret of its own. Left at its
      // default it produces an unread Secret holding LIGHTDASH_SECRET=changeme.
      // Nulling it keeps that value out of the cluster entirely.
      secrets: null,

      serviceAccount: {
        create: false,
        name: SERVICE_ACCOUNT_NAME,
      },

      configMap: {
        PORT: '8080',
        SITE_URL: siteUrl,
        SECURE_COOKIES: useTls ? 'true' : 'false',
        // The load balancer terminates the client connection, so the scheme
        // is only visible through X-Forwarded-Proto.
        TRUST_PROXY: 'true',
      },

      // Applied to the backend and to the worker.
      extraEnv: [
        ...sslEnv,
        { name: 'S3_ENDPOINT', value: `https://s3.${region}.amazonaws.com` },
        { name: 'S3_BUCKET', value: bucket.bucketName },
        { name: 'S3_REGION', value: region },
        // Pins credential resolution to the projected service account token
        // rather than letting the SDK walk the whole chain, which would
        // otherwise reach the node instance profile if IRSA were misconfigured
        // and grant whatever the nodes can do.
        { name: 'S3_USE_CREDENTIALS_FROM', value: 'token_file' },
      ],

      // Disabled, matching the chart default. With a single replica there is
      // no migration lock race for it to solve, and as a pre-install hook it
      // would run before External Secrets has produced the password. The env
      // is set so that enabling it later does not fail on SSL.
      migrationJob: {
        enabled: false,
        extraEnv: sslEnv,
      },

      ingress: {
        enabled: true,
        className: 'alb',
        annotations: {
          'alb.ingress.kubernetes.io/scheme': 'internet-facing',
          // Routes to pod IPs directly, which the VPC CNI makes routable.
          'alb.ingress.kubernetes.io/target-type': 'ip',
          'alb.ingress.kubernetes.io/healthcheck-path': HEALTH_CHECK_PATH,
          'alb.ingress.kubernetes.io/listen-ports': useTls
            ? '[{"HTTP":80},{"HTTPS":443}]'
            : '[{"HTTP":80}]',
          ...(useTls
            ? {
                'alb.ingress.kubernetes.io/certificate-arn': config.certificateArn!,
                'alb.ingress.kubernetes.io/ssl-redirect': '443',
              }
            : {}),
        },
        hosts: [
          {
            // An empty host matches any name, which is what makes the load
            // balancer's own DNS name usable before a domain exists.
            host: config.hostname ?? '',
            paths: [{ path: '/', pathType: 'Prefix' }],
          },
        ],
      },
    };

    this.release = cluster.addHelmChart('Lightdash', {
      repository: config.chartRepository,
      chart: 'lightdash',
      release: config.releaseName,
      namespace: config.namespace,
      version: config.chartVersion,
      wait: true,
      // Deliberately under the 15 minutes CDK gives its kubectl provider
      // Lambda. At exactly 15 the Lambda is killed while helm is still
      // waiting, CloudFormation retries, and the retry finds the release
      // pending-install and fails with "another operation is in progress",
      // which no redeploy clears. Losing the race on purpose leaves a failed
      // release instead, which the next deploy upgrades over.
      timeout: Duration.minutes(13),
      values,
    });

    this.release.node.addDependency(namespaceManifest, this.serviceAccount, ...dependencies);

    // Ordering that matters on the way down rather than up. The controller puts
    // a finalizer on the Ingress it provisions an ALB for, and only the
    // controller removes it. Without this the two can be torn down in either
    // order, and if the controller goes first the Ingress keeps its finalizer,
    // the namespace never leaves Terminating, the load balancer is left behind,
    // and destroy stops with no way forward but manual surgery.
    if (cluster.albController) {
      this.release.node.addDependency(cluster.albController);
    }
  }
}
