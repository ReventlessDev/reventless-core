// AWS managed cache policy — CachingOptimized (GET/HEAD, no query strings/cookies)
let cachingOptimizedPolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"

type bundleDistribution = {
  distributionUrl: Pulumi.Output.t<string>,
  bucketName: Pulumi.Output.t<string>,
}

/**
 * Provision an S3 bucket + CloudFront distribution for a UI bundle. When
 * `~assetsDir` is supplied, every file under it is uploaded as a `BucketObject`
 * with the correct MIME type and an etag derived from the file's SHA-256 so
 * Pulumi only re-uploads files that actually changed. When `~spaFallback=true`,
 * CloudFront 403/404 responses fall back to the index document so client-side
 * routes resolve correctly on first paint.
 *
 * Recommended call site for a SPA bundle:
 * ```rescript
 * let { distributionUrl } = Plugin_Stack.makeUiBundleDistribution(
 *   ~pluginId="my-console-bundle",
 *   ~bundleVersion="1.0.0",
 *   ~assetsDir=projectRoot ++ "/../../bundles/my-console/dist",
 *   ~spaFallback=true,
 * )
 * ```
 *
 * The caller must build the bundle (`vite build` or equivalent) before
 * `pulumi up`. Supplying `~assetsDir` for a missing or empty directory
 * fails fast with a clear error message.
 */
let makeUiBundleDistribution = (
  ~pluginId: string,
  ~bundleVersion: string,
  ~assetsDir: option<string>=?,
  ~spaFallback: bool=false,
  ~indexDocument: string="index.html",
): bundleDistribution => {
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

  let customErrorResponses = spaFallback
    ? [
        {
          PulumiAws.CloudFront.Distribution.errorCode: Pulumi.Input.make(403),
          responseCode: Pulumi.Input.make(200),
          responsePagePath: Pulumi.Input.make("/" ++ indexDocument),
          errorCachingMinTtl: Pulumi.Input.make(0),
        },
        {
          errorCode: Pulumi.Input.make(404),
          responseCode: Pulumi.Input.make(200),
          responsePagePath: Pulumi.Input.make("/" ++ indexDocument),
          errorCachingMinTtl: Pulumi.Input.make(0),
        },
      ]
    : []

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
      defaultRootObject: Pulumi.Input.make(indexDocument),
      customErrorResponses: Pulumi.Input.make(customErrorResponses),
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

  switch assetsDir {
  | None => ()
  | Some(dir) =>
    let entries = Util.StaticBundle.walk(dir)
    if entries->Array.length == 0 {
      JsError.throwWithMessage(
        `Plugin_Stack.makeUiBundleDistribution: assetsDir is empty: ${dir}`,
      )
    }
    entries->Array.forEach(entry => {
      let _ = PulumiAws.S3.BucketObject.make(
        ~name=name ++ "-asset-" ++ Util.StaticBundle.sanitizeName(entry.relativePath),
        ~args={
          bucket: bucket.id->Pulumi.Output.asInput,
          key: Pulumi.Input.make(entry.relativePath),
          source: Pulumi.Input.make(entry.fileAsset),
          contentType: Pulumi.Input.make(Util.StaticBundle.contentTypeFor(entry.relativePath)),
          etag: Pulumi.Input.make(entry.contentHash),
        },
      )
    })
  }

  {
    distributionUrl: distribution.domainName->Pulumi.Output.apply(d => "https://" ++ d),
    bucketName: bucket.bucket,
  }
}
