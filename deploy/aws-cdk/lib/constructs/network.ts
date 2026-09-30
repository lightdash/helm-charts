import { Tags } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { LightdashConfig } from '../config';

export interface NetworkProps {
  readonly config: LightdashConfig;
}

/**
 * VPC with public and private subnets across at least two availability zones.
 *
 * Nodes and the database sit in the private subnets; only load balancers are
 * placed publicly.
 */
export class Network extends Construct {
  public readonly vpc: ec2.Vpc;

  constructor(scope: Construct, id: string, props: NetworkProps) {
    super(scope, id);

    const { config } = props;

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr(config.vpcCidr),
      maxAzs: config.maxAzs,
      natGateways: config.natGateways,
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
        {
          name: 'private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 24,
        },
        {
          name: 'isolated',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
      ],
    });

    // The load balancer controller discovers subnets by tag. Without these it
    // reports "unable to discover at least one subnet" and no Ingress is ever
    // provisioned, which is the most common failure in an otherwise healthy
    // cluster. CDK does not add them.
    this.vpc.publicSubnets.forEach((subnet) => {
      Tags.of(subnet).add('kubernetes.io/role/elb', '1');
    });
    this.vpc.privateSubnets.forEach((subnet) => {
      Tags.of(subnet).add('kubernetes.io/role/internal-elb', '1');
    });
  }
}
