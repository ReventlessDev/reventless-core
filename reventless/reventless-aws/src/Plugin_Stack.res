// AWS managed cache policy — CachingOptimized (GET/HEAD, no query strings/cookies).
// Suited for hashed asset chunks whose URL changes on every build.
let cachingOptimizedPolicyId = "658327ea-f89d-4fab-a63d-7e88639e58f6"

// AWS managed cache policy — CachingDisabled (TTL 0). Used for unhashed entry
// points (`index.html`, `remoteEntry.js`, `config.json`) so a fresh `pulumi up`
// always surfaces the new manifest/config without a manual invalidation.
let cachingDisabledPolicyId = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

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
  ~stableName: bool=false,
  ~excludeFiles: array<string>=[],
): bundleDistribution => {
  // When stableName=true, Pulumi resource names omit bundleVersion so every
  // deploy updates the same bucket + CloudFront distribution in place. The
  // public CloudFront domain stays the same across releases. Per-file etags
  // still drive BucketObject diffs, and obsolete objects are removed when
  // their Pulumi resource disappears from state.
  //
  // When false (the default), bundleVersion is baked into every resource name,
  // so each release provisions a fresh bucket + distribution — useful for
  // plugin UI bundles whose URLs are resolved at runtime through the host
  // shell, where blue/green between versions is wanted.
  let name = stableName ? pluginId : pluginId ++ "-" ++ bundleVersion

  let bucket = PulumiAws.S3.Bucket.make(~name=name ++ "-bundle")

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

  // Pin paths that must never be cached at the CDN edge to the CachingDisabled
  // policy. Always cover `remoteEntry.js` (federation manifest) and, for SPA
  // shells, `index.html` + `config.json`. Hashed assets fall through to the
  // CachingOptimized default behavior since their URL changes on every build.
  let noCacheBehavior = (pattern: string): PulumiAws.CloudFront.Distribution.orderedCacheBehavior => {
    pathPattern: Pulumi.Input.make(pattern),
    targetOriginId: Pulumi.Input.make(originId),
    viewerProtocolPolicy: Pulumi.Input.make("redirect-to-https"),
    allowedMethods: Pulumi.Input.make(["GET", "HEAD"]),
    cachedMethods: Pulumi.Input.make(["GET", "HEAD"]),
    cachePolicyId: Pulumi.Input.make(cachingDisabledPolicyId),
  }
  let orderedCacheBehaviors = Array.concat(
    [noCacheBehavior("/remoteEntry.js")],
    spaFallback ? [noCacheBehavior("/" ++ indexDocument), noCacheBehavior("/config.json")] : [],
  )

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
      defaultCacheBehavior: Pulumi.Input.make(
        (
          {
            targetOriginId: Pulumi.Input.make(originId),
            viewerProtocolPolicy: Pulumi.Input.make("redirect-to-https"),
            allowedMethods: Pulumi.Input.make(["GET", "HEAD"]),
            cachedMethods: Pulumi.Input.make(["GET", "HEAD"]),
            cachePolicyId: Pulumi.Input.make(cachingOptimizedPolicyId),
          }: PulumiAws.CloudFront.Distribution.defaultCacheBehavior
        ),
      ),
      orderedCacheBehaviors: Pulumi.Input.make(orderedCacheBehaviors),
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
    let allEntries = Util.StaticBundle.walk(dir)
    if allEntries->Array.length == 0 {
      JsError.throwWithMessage(
        `Plugin_Stack.makeUiBundleDistribution: assetsDir is empty: ${dir}`,
      )
    }
    // Drop excluded relative paths before BucketObject creation. Used so the
    // host-shell deploy can skip the dev-mode `public/config.json` it ships
    // with — the explicit Platform.res BucketObject writes the production
    // config to the same S3 key and would otherwise race with the bundle
    // upload (whichever Pulumi applies last wins).
    let entries =
      allEntries->Array.filter(entry => !(excludeFiles->Array.includes(entry.relativePath)))
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
