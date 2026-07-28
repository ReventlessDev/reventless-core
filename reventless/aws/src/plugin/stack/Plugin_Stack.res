let log = ReventlessCore.Logger.fromEnv()

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

// Custom-domain config for a UI bundle's CloudFront distribution. When
// supplied, the bundle is served at `https://${fqdn}` instead of the default
// `*.cloudfront.net`. The framework provisions an ACM cert (us-east-1, as
// CloudFront requires), the DNS-01 validation records, and a Route53 A-alias
// pointing the FQDN at the distribution. The caller owns the Route53 zone.
type customDomain = {
  fqdn: string,
  hostedZoneId: string,
}

// CloudFront's global hosted zone ID for A/AAAA alias records — a fixed
// constant published by AWS. Used as the target zone when pointing a Route53
// record at any CloudFront distribution; not the distribution's own
// `hostedZoneId` output (which is meant for other Pulumi consumers).
let cloudFrontAliasZoneId = "Z2FDTNDATAQYW2"

// Lazy module-level us-east-1 Provider singleton. ACM certs consumed by
// CloudFront must live in us-east-1 regardless of the stack's primary
// region; sharing one provider across every UI bundle in the stack keeps the
// resource graph tidy. The singleton survives the whole Pulumi run because
// makeUiBundleDistribution may be invoked several times (host shell + future
// per-plugin SPAs) in a single deploy.
let _usEast1Provider: ref<option<PulumiAws.Aws.Provider.t>> = ref(None)
let _getUsEast1Provider = (): PulumiAws.Aws.Provider.t =>
  switch _usEast1Provider.contents {
  | Some(p) => p
  | None =>
    let p = PulumiAws.Aws.Provider.make(
      ~name="us-east-1",
      ~args={region: Pulumi.Input.make("us-east-1")},
    )
    _usEast1Provider := Some(p)
    p
  }

// ── Cache-Control ───────────────────────────────────────────────────────────

// Cache-Control for a bundle file. Vite emits content-hashed chunks under
// `assets/` whose URL changes whenever their content does, so they are safe to
// cache forever. Everything else is a STABLE-named entry point — `index.html`,
// the module-federation `mf-entry-bootstrap-*.js`, import maps, JSON — whose
// content changes IN PLACE across deploys, so it must always revalidate. Without
// `no-cache` here a redeploy uploads the new entry file to S3 while CloudFront
// (and browsers) keep serving the previous build: the "deployed but stale" trap.
let cacheControlFor = (relativePath: string): string =>
  relativePath->String.startsWith("assets/")
    ? "public, max-age=31536000, immutable"
    : "no-cache"

// ── Inline CloudFront SDK binding (deploy-time cache invalidation) ───────────
// Mirrors AppSync_Adapter's inline `@aws-sdk` binding pattern. Runs in the
// Pulumi deploy process (not a Lambda) with the deploy's ambient credentials.

type cloudFrontClient
type cfPaths = {
  @as("Quantity") quantity: int,
  @as("Items") items: array<string>,
}
type cfInvalidationBatch = {
  @as("CallerReference") callerReference: string,
  @as("Paths") paths: cfPaths,
}
type createInvalidationInput = {
  @as("DistributionId") distributionId: string,
  @as("InvalidationBatch") invalidationBatch: cfInvalidationBatch,
}
type createInvalidationCommand

@module("@aws-sdk/client-cloudfront") @new
external makeCloudFrontClient: unit => cloudFrontClient = "CloudFrontClient"
@module("@aws-sdk/client-cloudfront") @new
external makeCreateInvalidationCommand: createInvalidationInput => createInvalidationCommand =
  "CreateInvalidationCommand"
@send external cfSend: (cloudFrontClient, createInvalidationCommand) => promise<unknown> = "send"

// Best-effort CloudFront invalidation. Submits the batch (resolves once AWS
// accepts it — we do not wait for it to reach Completed) and never throws: a
// failed invalidation must not fail the deploy.
let invalidateDistribution = async (~distributionId: string, ~paths: array<string>): unit => {
  try {
    let client = makeCloudFrontClient()
    let input = {
      distributionId,
      invalidationBatch: {
        callerReference: "reventless-" ++ Date.now()->Float.toString,
        paths: {quantity: paths->Array.length, items: paths},
      },
    }
    let _ = await client->cfSend(input->makeCreateInvalidationCommand)
    log.info(~comp="makeUiBundleDistribution", `CloudFront invalidation submitted for ${distributionId}`)
  } catch {
  | exn =>
    let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
    log.info(~comp="makeUiBundleDistribution", `CloudFront invalidation skipped (${msg})`)
  }
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
  ~customDomain: option<customDomain>=?,
  ~servedBuckets: array<ReventlessInfra.Platform.servedBucket>=[],
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

  let bucket = PulumiAws.S3.Bucket.make(
    ~name=name ++ "-bundle",
    ~args={
      tags: AWS.Tags.make(
        ~name=name ++ "-bundle",
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Hosting,
        ~scope=Plugin,
        ~plugin=pluginId,
      ),
    },
  )

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
  // Ordered cache behavior routing a served bucket's `{prefix}/*` path to its own
  // origin. Served objects have immutable uuid keys ⇒ the long-TTL
  // CachingOptimized policy is safe. Prepended to `orderedCacheBehaviors` so a
  // served path is matched before the SPA-serving default behavior and never
  // routed to the bundle bucket.
  let servedOriginId = (id: string): string => "served-" ++ id
  let servedCacheBehavior = (
    ~prefix: string,
    ~originId: string,
  ): PulumiAws.CloudFront.Distribution.orderedCacheBehavior => {
    pathPattern: Pulumi.Input.make(prefix ++ "/*"),
    targetOriginId: Pulumi.Input.make(originId),
    viewerProtocolPolicy: Pulumi.Input.make("redirect-to-https"),
    allowedMethods: Pulumi.Input.make(["GET", "HEAD"]),
    cachedMethods: Pulumi.Input.make(["GET", "HEAD"]),
    cachePolicyId: Pulumi.Input.make(cachingOptimizedPolicyId),
  }
  let orderedCacheBehaviors = Array.concat(
    // One behavior per served prefix; several prefixes may share one origin when
    // they live in the same bucket.
    servedBuckets->Array.flatMap(sb =>
      sb.prefixes->Array.map(prefix =>
        servedCacheBehavior(~prefix, ~originId=servedOriginId(sb.id))
      )
    ),
    Array.concat(
      [noCacheBehavior("/remoteEntry.js")],
      spaFallback ? [noCacheBehavior("/" ++ indexDocument), noCacheBehavior("/config.json")] : [],
    ),
  )

  // Custom-domain provisioning. When `customDomain` is supplied the bundle is
  // served at `https://${fqdn}`: the framework creates an ACM cert in us-east-1
  // (CloudFront only consumes us-east-1 certs), the DNS-01 validation record in
  // the caller's hosted zone, a CertificateValidation that blocks until ACM
  // issues the cert, and a Route53 A-alias from the FQDN to the distribution.
  // When `None`, the cloudfront.net default URL is retained — no extra resources.
  //
  // Resource names below intentionally omit `bundleVersion`: the cert + alias
  // outlive a single deploy, so they must be stable across releases (unlike the
  // bucket / objects which already carry `bundleVersion` for cache-busting).
  let viewerCertificate: PulumiAws.CloudFront.Distribution.viewerCertificate = switch customDomain {
  | None => {
      cloudfrontDefaultCertificate: Pulumi.Input.make(true),
    }
  | Some({fqdn, hostedZoneId}) =>
    let usEast1 = _getUsEast1Provider()
    let cert = PulumiAws.Acm.Certificate.make(
      ~name=pluginId ++ "-domain-cert",
      ~args={
        domainName: Pulumi.Input.make(fqdn),
        validationMethod: Pulumi.Input.make("DNS"),
        tags: AWS.Tags.make(
          ~name=pluginId ++ "-domain-cert",
          ~kind=ReventlessCore.ComponentType.Plugin,
          ~role=Hosting,
          ~scope=Plugin,
          ~plugin=pluginId,
        ),
      },
      ~opts={provider: usEast1},
    )
    let firstValidationOption =
      cert.domainValidationOptions->Pulumi.Output.apply(opts => opts->Array.getUnsafe(0))
    let validationRecord = PulumiAws.Route53.Record.make(
      ~name=pluginId ++ "-domain-validation-record",
      ~args={
        zoneId: Pulumi.Input.make(hostedZoneId),
        name: firstValidationOption
        ->Pulumi.Output.apply(o => o.resourceRecordName)
        ->Pulumi.Output.asInput,
        type_: firstValidationOption
        ->Pulumi.Output.apply(o => o.resourceRecordType)
        ->Pulumi.Output.asInput,
        ttl: Pulumi.Input.make(60),
        records: firstValidationOption
        ->Pulumi.Output.apply(o => [o.resourceRecordValue])
        ->Pulumi.Output.asInput,
        // ACM renewals reuse the same validation token, so the record is
        // stable. allowOverwrite avoids spurious "record already exists"
        // errors on redeploys where the in-state record was wiped manually.
        allowOverwrite: Pulumi.Input.make(true),
      },
    )
    let validated = PulumiAws.Acm.CertificateValidation.make(
      ~name=pluginId ++ "-domain-cert-validation",
      ~args={
        certificateArn: cert.arn->Pulumi.Output.asInput,
        validationRecordFqdns: [validationRecord.fqdn]
        ->Pulumi.Output.all
        ->Pulumi.Output.asInput,
      },
      ~opts={provider: usEast1},
    )
    {
      acmCertificateArn: validated.certificateArn->Pulumi.Output.asInput,
      sslSupportMethod: Pulumi.Input.make("sni-only"),
      minimumProtocolVersion: Pulumi.Input.make("TLSv1.2_2021"),
    }
  }

  let distribution = PulumiAws.CloudFront.Distribution.make(
    ~name=name ++ "-cdn",
    ~args={
      enabled: Pulumi.Input.make(true),
      aliases: ?switch customDomain {
      | None => None
      | Some({fqdn}) => Some(Pulumi.Input.make([fqdn]))
      },
      origins: (bucket.bucketRegionalDomainName, oac.id)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((domainName, oacId)) =>
          Array.concat(
            [
              {
                PulumiAws.CloudFront.Distribution.domainName: Pulumi.Input.make(domainName),
                originId: Pulumi.Input.make(originId),
                originAccessControlId: Pulumi.Input.make(oacId),
              },
            ],
            // One S3 origin per served bucket, sharing the same OAC as the bundle
            // origin (the OAC only authorizes CloudFront→S3 sigv4 signing; the
            // per-bucket read grant is the served bucket's own BucketPolicy below).
            servedBuckets->Array.map(sb => {
              PulumiAws.CloudFront.Distribution.domainName: sb.bucketRegionalDomainName,
              originId: Pulumi.Input.make(servedOriginId(sb.id)),
              originAccessControlId: Pulumi.Input.make(oacId),
            }),
          )
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
      viewerCertificate: Pulumi.Input.make(viewerCertificate),
      comment: Pulumi.Input.make(pluginId ++ " UI bundle CDN"),
      defaultRootObject: Pulumi.Input.make(indexDocument),
      customErrorResponses: Pulumi.Input.make(customErrorResponses),
      tags: AWS.Tags.make(
        ~name=name ++ "-cdn",
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Hosting,
        ~scope=Plugin,
        ~plugin=pluginId,
      ),
    },
  )

  // Route53 A-alias from the FQDN to the freshly-created distribution. Lives
  // in the caller's hosted zone (NOT the us-east-1 cert provider's zone — the
  // zone is wherever the caller put it). CloudFront's global alias zone ID is
  // a fixed constant; see `cloudFrontAliasZoneId`.
  switch customDomain {
  | None => ()
  | Some({fqdn, hostedZoneId}) =>
    let _ = PulumiAws.Route53.Record.make(
      ~name=pluginId ++ "-domain-alias",
      ~args={
        zoneId: Pulumi.Input.make(hostedZoneId),
        name: Pulumi.Input.make(fqdn),
        type_: Pulumi.Input.make("A"),
        aliases: [
          (
            {
              name: distribution.domainName->Pulumi.Output.asInput,
              zoneId: Pulumi.Input.make(cloudFrontAliasZoneId),
              evaluateTargetHealth: Pulumi.Input.make(false),
            }: PulumiAws.Route53.Record.alias
          ),
        ]->Pulumi.Input.make,
      },
    )
  }

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

  // Per served bucket: grant CloudFront read scoped to THIS distribution, so the
  // object is fetchable at `https://<ui-domain>/{prefix}/<key>` while the bucket
  // stays private (direct S3 GET is 403). Mirrors the bundle bucket policy above;
  // the served bucket keeps its own all-true BucketPublicAccessBlock (app-owned).
  //
  // Exactly one policy per bucket — S3 permits no more. Grouping prefixes into
  // one `servedBucket` is what makes that structural rather than a rule to
  // remember.
  servedBuckets->Array.forEach(sb => {
    let _ = PulumiAws.S3.BucketPolicy.make(
      ~name=name ++ "-served-" ++ sb.id ++ "-policy",
      ~args={
        bucket: sb.bucketId,
        policy: (sb.bucketArn->Pulumi.Output.fromInput, distribution.arn)
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
  })

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
    let objectEtags =
      entries->Array.map(entry => {
        let obj = PulumiAws.S3.BucketObject.make(
          ~name=name ++ "-asset-" ++ Util.StaticBundle.sanitizeName(entry.relativePath),
          ~args={
            bucket: bucket.id->Pulumi.Output.asInput,
            key: Pulumi.Input.make(entry.relativePath),
            source: Pulumi.Input.make(entry.fileAsset),
            contentType: Pulumi.Input.make(Util.StaticBundle.contentTypeFor(entry.relativePath)),
            cacheControl: Pulumi.Input.make(cacheControlFor(entry.relativePath)),
            etag: Pulumi.Input.make(entry.contentHash),
          },
        )
        obj.etag
      })

    // Auto-invalidate CloudFront once every object is (re)uploaded. Stable-named
    // entry files (index.html, the module-federation mf-entry-bootstrap-*.js)
    // are served by the long-TTL default cache behaviour, so without this a
    // `pulumi up` lands the new bundle in S3 while CloudFront keeps serving the
    // prior build until its TTL expires. Chained on the upload etags so it runs
    // AFTER the new content is in S3; `/*` is a single invalidation path (well
    // within CloudFront's free-tier monthly allowance even on frequent deploys).
    let _ =
      (distribution.id, Pulumi.Output.all(objectEtags))
      ->Pulumi.Output.all2
      ->Pulumi.Output.flatMap(((distId, _etags)) =>
        invalidateDistribution(~distributionId=distId, ~paths=["/*"])->Pulumi.Output.fromPromise
      )
  }

  // When a custom domain is provisioned, return the pretty FQDN URL — the
  // *.cloudfront.net hostname stops accepting requests once `aliases` is set,
  // so the only viable public URL is the FQDN. Downstream consumers
  // (`hostShellUrl` export, host-shell `config.json`) see the pretty URL
  // transparently; no per-call-site change required.
  let distributionUrl = switch customDomain {
  | Some({fqdn}) => Pulumi.Output.make("https://" ++ fqdn)
  | None => distribution.domainName->Pulumi.Output.apply(d => "https://" ++ d)
  }

  {
    distributionUrl,
    bucketName: bucket.bucket,
  }
}
