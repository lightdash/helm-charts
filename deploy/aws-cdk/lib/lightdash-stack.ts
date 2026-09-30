import { CfnOutput, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import { LightdashConfig } from './config';
import { Application } from './constructs/application';
import { Cluster } from './constructs/cluster';
import { Database } from './constructs/database';
import { Network } from './constructs/network';
import { LIGHTDASH_SECRET_KEY, SecretSync } from './constructs/secret-sync';
import { Storage } from './constructs/storage';

export interface LightdashStackProps extends StackProps {
  readonly config: LightdashConfig;
}

/**
 * Everything the deployment creates, in one stack.
 *
 * One stack rather than several because the alternative means exporting a
 * security group and a VPC across stack boundaries, and CloudFormation then
 * refuses to update an export while the consuming stack references it. That
 * turns routine changes into manual export surgery, which is a poor trade for
 * a deployment an operator runs end to end.
 */
export class LightdashStack extends Stack {
  constructor(scope: Construct, id: string, props: LightdashStackProps) {
    super(scope, id, props);

    const { config } = props;
    const retain = config.retainData;

    const network = new Network(this, 'Network', { config });

    const storage = new Storage(this, 'Storage', { config });

    const database = new Database(this, 'Database', {
      config,
      vpc: network.vpc,
    });

    // Signs session cookies and encrypts stored warehouse credentials, so
    // losing it invalidates every saved connection. Generated here so that no
    // human ever sees it and the chart's "changeme" default is never used.
    const applicationSecret = new secretsmanager.Secret(this, 'ApplicationSecret', {
      description: 'Lightdash LIGHTDASH_SECRET',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({}),
        generateStringKey: LIGHTDASH_SECRET_KEY,
        passwordLength: 64,
        excludePunctuation: true,
      },
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    const cluster = new Cluster(this, 'Compute', {
      config,
      vpc: network.vpc,
    });

    // Managed node groups attach the cluster security group, so this is what
    // opens PostgreSQL to the pods.
    database.allowFrom(cluster.cluster, 'Lightdash pods on EKS');

    const namespaceManifest = cluster.cluster.addManifest('AppNamespace', {
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: { name: config.namespace },
    });
    // Deleting a namespace waits for every pod in it to terminate, and a pod
    // whose node has already gone never reports that it has. Depending on the
    // node group puts the namespace ahead of it on the way down.
    namespaceManifest.node.addDependency(cluster.nodegroup);

    const secretSync = new SecretSync(this, 'SecretSync', {
      cluster: cluster.cluster,
      nodegroup: cluster.nodegroup,
      appNamespace: config.namespace,
      appNamespaceManifest: namespaceManifest,
      databaseSecret: database.secret,
      applicationSecret,
      region: this.region,
    });

    new Application(this, 'Application', {
      config,
      cluster: cluster.cluster,
      namespaceManifest,
      bucket: storage.bucket,
      database: database.instance,
      databaseName: database.databaseName,
      databaseUser: database.databaseUser,
      region: this.region,
      dependencies: secretSync.manifests,
    });

    new CfnOutput(this, 'ClusterName', {
      value: cluster.cluster.clusterName,
    });

    new CfnOutput(this, 'KubeconfigCommand', {
      description: 'Run this to point kubectl at the new cluster',
      value: `aws eks update-kubeconfig --region ${this.region} --name ${cluster.cluster.clusterName}`,
    });

    new CfnOutput(this, 'IngressAddressCommand', {
      description: 'The load balancer takes a few minutes to appear after the release',
      value: `kubectl -n ${config.namespace} get ingress ${config.releaseName} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`,
    });

    new CfnOutput(this, 'DatabaseEndpoint', {
      value: database.instance.instanceEndpoint.hostname,
    });

    new CfnOutput(this, 'StorageBucket', {
      value: storage.bucket.bucketName,
    });

    new CfnOutput(this, 'DatabaseSecretArn', {
      description: 'Read the password with: aws secretsmanager get-secret-value --secret-id',
      value: database.secret.secretArn,
    });
  }
}
