import { KubectlV31Layer } from '@aws-cdk/lambda-layer-kubectl-v31';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import { Construct } from 'constructs';
import { LightdashConfig } from '../config';

export interface ClusterProps {
  readonly config: LightdashConfig;
  readonly vpc: ec2.IVpc;
}

/**
 * Load balancer controller version. Pinned so that a redeploy months later
 * installs the same controller instead of whatever is current.
 *
 * A named version is used rather than AlbControllerVersion.of() because CDK
 * bundles the matching IAM policy only for versions it knows, and requires the
 * caller to supply the whole policy document for any other.
 */
const ALB_CONTROLLER_VERSION = eks.AlbControllerVersion.V2_13_4;

/**
 * EKS cluster, its managed node group, and the AWS Load Balancer Controller.
 *
 * The kubectl Lambda layer is pinned to a Kubernetes minor version by its
 * package name, so raising `kubernetesVersion` past 1.31 also means depending
 * on the matching @aws-cdk/lambda-layer-kubectl-vNN package and importing it
 * here. There is no way to make that automatic.
 */
export class Cluster extends Construct {
  public readonly cluster: eks.Cluster;
  public readonly nodegroup: eks.Nodegroup;

  constructor(scope: Construct, id: string, props: ClusterProps) {
    super(scope, id);

    const { config, vpc } = props;

    this.cluster = new eks.Cluster(this, 'Cluster', {
      version: eks.KubernetesVersion.of(config.kubernetesVersion),
      kubectlLayer: new KubectlV31Layer(this, 'KubectlLayer'),
      vpc,
      vpcSubnets: [{ subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS }],
      // Capacity is added below as a managed node group, which supports
      // rolling AMI updates that the default self-managed ASG does not.
      defaultCapacity: 0,
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      // Access entries as well as aws-auth. Under CONFIG_MAP alone the only
      // principal that can reach the API server is the role CDK created the
      // cluster with, and nobody can be added without already holding access,
      // so the operator who ran the deploy cannot run kubectl at all. With the
      // API mode on they can grant themselves an access entry from IAM. See the
      // README.
      authenticationMode: eks.AuthenticationMode.API_AND_CONFIG_MAP,
      albController: { version: ALB_CONTROLLER_VERSION },
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
      ],
    });

    this.nodegroup = this.cluster.addNodegroupCapacity('Nodes', {
      instanceTypes: [new ec2.InstanceType(config.nodeInstanceType)],
      minSize: config.nodeMinSize,
      maxSize: config.nodeMaxSize,
      desiredSize: config.nodeDesiredSize,
      diskSize: config.nodeDiskSizeGb,
      subnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
    });

    // The controller's Helm release waits for its pods to become ready, and
    // with defaultCapacity at 0 there is nothing to schedule on until the node
    // group exists. Without this ordering the first deploy can time out.
    this.cluster.albController?.node.addDependency(this.nodegroup);

    if (config.adminRoleArn) {
      // An access entry rather than an aws-auth mapping, because aws-auth is
      // edited by the kubectl provider from inside the cluster and an access
      // entry is an EKS API call, so it still lands if the cluster is
      // unreachable.
      this.cluster.grantAccess('AdminAccess', config.adminRoleArn, [
        eks.AccessPolicy.fromAccessPolicyName('AmazonEKSClusterAdminPolicy', {
          accessScopeType: eks.AccessScopeType.CLUSTER,
        }),
      ]);
    }
  }
}
