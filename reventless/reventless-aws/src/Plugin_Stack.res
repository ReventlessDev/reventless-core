// AWS managed cache policy — CachingOptimized (GET/HEAD, no query strings/cookies)
let cachingOptimizedPolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"

type bundleDistribution = {
  distributionUrl: Pulumi.Output.t<string>,
  bucketName: Pulumi.Output.t<string>,
}

let makeUiBundleDistribution = (~pluginId: string, ~bundleVersion: string): bundleDistribution => {
  let name = pluginId ++ "-" ++ bundleVersion

  let bucket = PulumiAws.S3.BucketV2.make(~name=name ++ "-bundle")

  let _ = PulumiAws.S3.BucketPublicAccessBlock.make(
    ~name=name ++ "-bundle-pab",
    ~args={
      bucket: bucket.id->Pulumi.Output.asInput,
      blockPublicAcls: Pulumi.Input.make(true),
      blockPublicPolicy: Pulumi.Input.make(true),
      ignorePublicAcls: Pulumi.Input.make(true),
      restrictPublicBuckets: Pulumi.Input.make(true),
    },
  )

  let oac = PulumiAws.CloudFront.OriginAccessControl.make(
    ~name=name ++ "-oac",
    ~args={
      originAccessControlOriginType: Pulumi.Input.make("s3"),
      signingBehavior: Pulumi.Input.make("always"),
      signingProtocol: Pulumi.Input.make("sigv4"),
    },
  )

  let originId = pluginId ++ "-s3"

  let distribution = PulumiAws.CloudFront.Distribution.make(
    ~name=name ++ "-cdn",
    ~args={
      enabled: Pulumi.Input.make(true),
      origins: (bucket.bucketRegionalDomainName, oac.id)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((domainName, oacId)) =>
          [
            {
              PulumiAws.CloudFront.Distribution.domainName: Pulumi.Input.make(domainName),
              originId: Pulumi.Input.make(originId),
              originAccessControlId: Pulumi.Input.make(oacId),
            },
          ]
        )
        ->Pulumi.Output.asInput,
      defaultCacheBehavior: Pulumi.Input.make({
        PulumiAws.CloudFront.Distribution.targetOriginId: Pulumi.Input.make(originId),
        viewerProtocolPolicy: Pulumi.Input.make("redirect-to-https"),
        allowedMethods: Pulumi.Input.make(["GET", "HEAD"]),
        cachedMethods: Pulumi.Input.make(["GET", "HEAD"]),
        cachePolicyId: Pulumi.Input.make(cachingOptimizedPolicyId),
      }),
      restrictions: Pulumi.Input.make({
        PulumiAws.CloudFront.Distribution.geoRestriction: Pulumi.Input.make({
          PulumiAws.CloudFront.Distribution.restrictionType: Pulumi.Input.make("none"),
        }),
      }),
      viewerCertificate: Pulumi.Input.make({
        PulumiAws.CloudFront.Distribution.cloudfrontDefaultCertificate: Pulumi.Input.make(true),
      }),
      comment: Pulumi.Input.make(pluginId ++ " UI bundle CDN"),
    },
  )

  let _ = PulumiAws.S3.BucketPolicy.make(
    ~name=name ++ "-bundle-policy",
    ~args={
      bucket: bucket.id->Pulumi.Output.asInput,
      policy: (bucket.arn, distribution.arn)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((bucketArn, distributionArn)) =>
          {
            "Version": "2012-10-17",
            "Statement": [
              {
                "Sid": "AllowCloudFrontServicePrincipal",
                "Effect": "Allow",
                "Principal": {"Service": "cloudfront.amazonaws.com"},
                "Action": "s3:GetObject",
                "Resource": bucketArn ++ "/*",
                "Condition": {
                  "StringEquals": {"AWS:SourceArn": distributionArn},
                },
              },
            ],
          }
          ->JSON.stringifyAny
          ->Option.getUnsafe
        )
        ->Pulumi.Output.asInput,
    },
  )

  {
    distributionUrl: distribution.domainName->Pulumi.Output.apply(d => "https://" ++ d),
    bucketName: bucket.bucket,
  }
}
