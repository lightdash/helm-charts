import { Duration } from 'aws-cdk-lib';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface SecretSyncProps {
  readonly cluster: eks.Cluster;
  /** The operator needs somewhere to run before its install can complete. */
  readonly nodegroup: eks.Nodegroup;
  /** Namespace the Lightdash release runs in. Must already exist. */
  readonly appNamespace: string;
  /** Applied before anything targeting appNamespace. */
  readonly appNamespaceManifest: eks.KubernetesManifest;
  readonly databaseSecret: secretsmanager.ISecret;
  readonly applicationSecret: secretsmanager.ISecret;
  readonly region: string;
}

const ESO_NAMESPACE = 'external-secrets';
const ESO_SERVICE_ACCOUNT = 'external-secrets';
/** Pinned so a redeploy installs the same operator. */
const ESO_CHART_VERSION = '0.10.4';
const SECRET_STORE_NAME = 'aws-secrets-manager';

/** Kubernetes Secret names this construct produces. */
export const DATABASE_SECRET_NAME = 'lightdash-database';
export const DATABASE_PASSWORD_KEY = 'postgresql-password';
export const APPLICATION_SECRET_NAME = 'lightdash-application';
export const LIGHTDASH_SECRET_KEY = 'LIGHTDASH_SECRET';

/**
 * Copies credentials from Secrets Manager into Kubernetes Secrets using the
 * External Secrets Operator.
 *
 * The alternative, passing the password straight into Helm values, would place
 * the plaintext in the CloudFormation template and in the kubectl provider's
 * event payload. Reading it inside the cluster instead means the only copies
 * are in Secrets Manager and in etcd. The operator also refreshes on its own,
 * so rotating the RDS secret does not require a redeploy.
 */
export class SecretSync extends Construct {
  /** Depend on this before scheduling any pod that consumes the secrets. */
  public readonly manifests: eks.KubernetesManifest[];

  constructor(scope: Construct, id: string, props: SecretSyncProps) {
    super(scope, id);

    const {
      cluster,
      nodegroup,
      appNamespace,
      appNamespaceManifest,
      databaseSecret,
      applicationSecret,
      region,
    } = props;

    const namespace = cluster.addManifest('EsoNamespace', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: ESO_NAMESPACE },
    });

    // The controller reads Secrets Manager with this identity. CDK builds the
    // OIDC trust policy, which needs the cluster issuer inside a condition
    // key and cannot be written by hand in CloudFormation.
    const serviceAccount = cluster.addServiceAccount('EsoServiceAccount', {
      name: ESO_SERVICE_ACCOUNT,
      namespace: ESO_NAMESPACE,
    });
    serviceAccount.node.addDependency(namespace);

    databaseSecret.grantRead(serviceAccount);
    applicationSecret.grantRead(serviceAccount);

    const operator = cluster.addHelmChart('ExternalSecrets', {
      repository: 'https://charts.external-secrets.io',
      chart: 'external-secrets',
      release: 'external-secrets',
      namespace: ESO_NAMESPACE,
      version: ESO_CHART_VERSION,
      // The CRDs and the validating webhook must both be live before any
      // SecretStore or ExternalSecret is applied, so block here rather than
      // letting the next manifest fail on an unknown kind.
      wait: true,
      timeout: Duration.minutes(10),
      values: {
        installCRDs: true,
        serviceAccount: {
          create: false,
          name: ESO_SERVICE_ACCOUNT,
        },
      },
    });
    // The node group is created in parallel with the cluster's kubectl
    // provider, so without this the install can start before any node has
    // registered, leave three deployments pending, and time out.
    operator.node.addDependency(serviceAccount, nodegroup);

    // Namespaced rather than a ClusterSecretStore. A cluster-scoped store can
    // be named by an ExternalSecret in any namespace, so a workload with no
    // access to this one could still ask the operator to fetch the database
    // password on its behalf. Scoping the store to the release namespace means
    // only something already inside it can do that.
    const secretStore = cluster.addManifest('SecretStore', {
      apiVersion: 'external-secrets.io/v1beta1',
      kind: 'SecretStore',
      metadata: { name: SECRET_STORE_NAME, namespace: appNamespace },
      spec: {
        provider: {
          aws: {
            service: 'SecretsManager',
            region,
            // auth is omitted on purpose: the controller then uses its pod
            // identity, which is the IRSA role above.
          },
        },
      },
    });
    secretStore.node.addDependency(operator, appNamespaceManifest);

    const databaseExternalSecret = cluster.addManifest('DatabaseExternalSecret', {
      apiVersion: 'external-secrets.io/v1beta1',
      kind: 'ExternalSecret',
      metadata: { name: DATABASE_SECRET_NAME, namespace: appNamespace },
      spec: {
        refreshInterval: '1h',
        secretStoreRef: { name: SECRET_STORE_NAME, kind: 'SecretStore' },
        target: { name: DATABASE_SECRET_NAME, creationPolicy: 'Owner' },
        data: [
          {
            // The chart reads the password under this key, set by
            // externalDatabase.secretKeys.passwordKey.
            secretKey: DATABASE_PASSWORD_KEY,
            remoteRef: {
              key: databaseSecret.secretArn,
              property: 'password',
            },
          },
        ],
      },
    });
    databaseExternalSecret.node.addDependency(secretStore, appNamespaceManifest);

    const applicationExternalSecret = cluster.addManifest('ApplicationExternalSecret', {
      apiVersion: 'external-secrets.io/v1beta1',
      kind: 'ExternalSecret',
      metadata: { name: APPLICATION_SECRET_NAME, namespace: appNamespace },
      spec: {
        refreshInterval: '1h',
        secretStoreRef: { name: SECRET_STORE_NAME, kind: 'SecretStore' },
        // envFrom injects every key in this Secret, so it holds only values
        // Lightdash expects to see as environment variables.
        target: { name: APPLICATION_SECRET_NAME, creationPolicy: 'Owner' },
        data: [
          {
            secretKey: LIGHTDASH_SECRET_KEY,
            remoteRef: {
              key: applicationSecret.secretArn,
              property: LIGHTDASH_SECRET_KEY,
            },
          },
        ],
      },
    });
    applicationExternalSecret.node.addDependency(secretStore, appNamespaceManifest);

    this.manifests = [databaseExternalSecret, applicationExternalSecret];
  }
}
