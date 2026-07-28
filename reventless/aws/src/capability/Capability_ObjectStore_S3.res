// An object store, provisioned with the framework's house conventions applied.
//
// Deployments used to hand-write this bucket with raw Pulumi, which meant every
// convention the framework applies to its own buckets had to be remembered by
// hand — and the attribution tags in particular were routinely forgotten. Tags
// are not cosmetic here: operational tooling discovers a platform's resources
// *only* through `reventless:platform` + `reventless:environment` tag filters
// against the Resource Groups Tagging API, so an untagged bucket is invisible
// to it. A store wipe would then leave every uploaded object behind while the
// events referencing them are gone.
//
// The returned record is what `deployPlatform`'s `~hostUiBundle` takes, so the
// bucket is described once and both the write path (presigned PUTs) and the
// read path (served read-only from the UI origin) are derived from it.
//
// Encryption and versioning are deliberately left at the account/AWS defaults,
// matching the framework's own buckets (`TaskBucket_S3`, the plugin bundle
// bucket): S3 applies AES256 to new buckets by default, and versioning is
// one-way — once enabled it can be suspended but never removed — so it changes
// both cost and delete semantics and belongs to a deployment's judgement rather
// than to a framework default.
//
// Follow-up, once a store's lifecycle follows a declaration rather than an
// explicit line of app code: `protect` / `retainOnDelete`, so an accidental
// removal of that declaration cannot destroy a bucket holding live objects.

open PulumiAws

// Browser direct-PUT needs CORS. These defaults match what deployments wrote by
// hand; `~corsRules` overrides them for a store the browser never touches.
let defaultCorsRules: S3.Bucket.corsRules = [
  {
    S3.Bucket.allowedHeaders: ["*"],
    allowedMethods: ["HEAD", "GET", "PUT", "POST"],
    allowedOrigins: ["*"],
    exposeHeaders: ["ETag"],
    maxAgeSeconds: 3000,
  },
]

/** Create an object store bucket with framework attribution tags and an
    all-true public-access block. */
let make = (
  ~name: string,
  ~corsRules: S3.Bucket.corsRules=defaultCorsRules,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
): ReventlessInfra.Platform.objectStore => {
  let bucket = S3.Bucket.make(
    ~name,
    ~args={
      corsRules: corsRules->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Other("ObjectStore"),
        ~scope=Platform,
      ),
    },
    ~opts?,
  )

  // A served store is read through the UI's CDN via an origin access control,
  // never directly, so it keeps its own all-true public-access block. Account
  // level S3 defaults happen to cover this today, which makes its absence a
  // latent gap rather than a live exposure — but one that turns live the moment
  // an account default changes.
  let _pab = S3.BucketPublicAccessBlock.make(
    ~name=name ++ "-pab",
    ~args={
      bucket: bucket.id->Pulumi.Output.asInput,
      blockPublicAcls: Pulumi.Input.make(true),
      blockPublicPolicy: Pulumi.Input.make(true),
      ignorePublicAcls: Pulumi.Input.make(true),
      restrictPublicBuckets: Pulumi.Input.make(true),
    },
  )

  {
    bucketName: bucket.bucket->Pulumi.Output.asInput,
    bucketId: bucket.id->Pulumi.Output.asInput,
    bucketArn: bucket.arn->Pulumi.Output.asInput,
    bucketRegionalDomainName: bucket.bucketRegionalDomainName->Pulumi.Output.asInput,
  }
}
