import { Duration, RemovalPolicy } from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { LightdashConfig } from '../config';

export interface StorageProps {
  readonly config: LightdashConfig;
}

/**
 * Object storage for Lightdash results, charts and uploaded images.
 *
 * Lightdash requires S3-compatible storage: parseBaseS3Config throws unless
 * S3_ENDPOINT, S3_BUCKET and S3_REGION are all set, so this bucket is not
 * optional for a working instance.
 */
export class Storage extends Construct {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: StorageProps) {
    super(scope, id);

    const { config } = props;
    const retain = config.retainData;

    this.bucket = new s3.Bucket(this, 'Bucket', {
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: retain ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
      // Without this, destroying a non-empty bucket fails and leaves the stack
      // in DELETE_FAILED.
      autoDeleteObjects: !retain,
      lifecycleRules: [
        {
          // Multipart uploads that never completed are billed but unreachable.
          abortIncompleteMultipartUploadAfter: Duration.days(7),
        },
      ],
      // Lightdash mints presigned PUT URLs that the browser uploads to
      // directly, so the browser origin must be allowed at the bucket.
      cors: [
        {
          allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.PUT, s3.HttpMethods.HEAD],
          allowedOrigins: config.hostname ? [`https://${config.hostname}`] : ['*'],
          allowedHeaders: ['*'],
          exposedHeaders: ['ETag'],
          maxAge: 3000,
        },
      ],
    });
  }
}
