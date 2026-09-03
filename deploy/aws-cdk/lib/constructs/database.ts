import { Annotations, Duration, RemovalPolicy } from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import { LightdashConfig } from '../config';

export interface DatabaseProps {
  readonly config: LightdashConfig;
  readonly vpc: ec2.IVpc;
}

/** Database name and user created on the instance. */
const DATABASE_NAME = 'lightdash';
const DATABASE_USER = 'lightdash';

/**
 * RDS PostgreSQL for the Lightdash metadata database, replacing the chart's
 * bundled postgresql subchart.
 *
 * The password is generated into Secrets Manager and never leaves it: it
 * reaches the cluster through External Secrets, so no plaintext credential is
 * present in the CloudFormation template, in CDK context, or in Helm values.
 */
export class Database extends Construct {
  public readonly instance: rds.DatabaseInstance;
  public readonly secret: secretsmanager.ISecret;
  public readonly databaseName = DATABASE_NAME;
  public readonly databaseUser = DATABASE_USER;

  constructor(scope: Construct, id: string, props: DatabaseProps) {
    super(scope, id);

    const { config, vpc } = props;
    const retain = config.retainData;

    this.instance = new rds.DatabaseInstance(this, 'Instance', {
      engine: rds.DatabaseInstanceEngine.postgres({
        // Built from config rather than a PostgresEngineVersion constant so
        // that upgrading the engine does not require a new aws-cdk-lib.
        version: rds.PostgresEngineVersion.of(
          config.postgresVersion,
          config.postgresMajorVersion,
        ),
      }),
      instanceType: new ec2.InstanceType(config.dbInstanceType),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      publiclyAccessible: false,
      multiAz: false,
      allocatedStorage: config.dbAllocatedStorageGb,
      maxAllocatedStorage: config.dbMaxAllocatedStorageGb,
      storageEncrypted: true,
      databaseName: DATABASE_NAME,
      credentials: rds.Credentials.fromGeneratedSecret(DATABASE_USER, {
        // The default generator includes characters that break libpq
        // connection strings and Kubernetes env interpolation.
        excludeCharacters: ' %+~`#$&*()|[]{}:;<>?!\'/"\\@',
      }),
      backupRetention: Duration.days(config.dbBackupRetentionDays),
      deleteAutomatedBackups: !retain,
      // Off by default, and not tied to retainData. Protection makes RDS
      // reject the delete that either removal policy asks for, so pairing the
      // two would leave the stack in DELETE_FAILED with no snapshot taken,
      // which is the opposite of what retainData promises.
      deletionProtection: config.dbDeletionProtection,
      removalPolicy: retain ? RemovalPolicy.SNAPSHOT : RemovalPolicy.DESTROY,
    });

    if (config.dbDeletionProtection) {
      Annotations.of(this).addWarning(
        'dbDeletionProtection is on, so `cdk destroy` will fail at the database. Redeploy ' +
          'with -c dbDeletionProtection=false first, then destroy.',
      );
    }

    if (!this.instance.secret) {
      throw new Error('Expected fromGeneratedSecret to attach a secret to the instance');
    }
    this.secret = this.instance.secret;
  }

  /** Allows the given peer to reach PostgreSQL. */
  public allowFrom(peer: ec2.IConnectable, description: string): void {
    this.instance.connections.allowDefaultPortFrom(peer, description);
  }
}
