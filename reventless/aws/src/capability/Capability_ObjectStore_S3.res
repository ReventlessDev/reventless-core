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
// A store's lifecycle now follows a *declaration*, which changes the risk. A
// hand-written bucket could only be destroyed by editing a line of Pulumi; a
// declared one can be destroyed by renaming a field, because the last
// `@storageRef("productImages")` disappearing removes the requirement. Hence
// `~protect`, on by default and turned off only for stacks that are routinely
// torn down — see `Util_StoreLayout.protectionFor`, which decides that from
// disposability rather than from the store's layout.
//
// Not to be confused with the framework's other buckets: a **store** is
// declared by a field's type and holds values that events reference, so its
// objects outlive any single deploy. A **task bucket** (`TaskBucket_S3`) is
// wired by a slice and holds transient input, and the plugin-bundle and
// host-ui-bundle buckets are hosting substrate. Neither has a `@storageRef`
// field pointing at it, and neither is provisioned from a declaration.

open PulumiAws

/** One prefix in this bucket whose never-claimed uploads expire, and after how
    many days. A list rather than a scalar because a shared-layout bucket holds
    several stores, and expiry is opt-in per store. */
type pendingExpiry = {
  prefix: string,
  days: int,
}

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
    all-true public-access block.

    `~keyPrefix` is the path this store's object keys are rooted at; it travels
    in the returned record so the mint side and the serve side read one value
    instead of restating it.

    `~plugin` attributes the store to the plugin whose field declared it. The
    bucket is created by the platform deploy — that is where the serving CDN and
    the presign services live, and where a shared bucket has a single owner — so
    ownership is expressed in the tags rather than in which stack ran `make`.

    `~protect` (default on) blocks `pulumi destroy` and accidental replacement.
    `~forceDestroy` is its counterpart for disposable stacks: a protected bucket
    cannot be torn down, so a PR stack would leak exactly the buckets that
    sharing exists to save.

    `~expirePending` turns on the sweep of never-claimed uploads. One entry per
    prefix rather than one setting for the bucket, because a shared-layout
    bucket holds several stores and the setting is each store's own — see the
    comment on the rule below before setting it. */
let make = (
  ~name: string,
  ~keyPrefix: string=Upload_Presign_S3.defaultServedPrefix,
  ~plugin: option<string>=?,
  ~protect: bool=true,
  ~forceDestroy: bool=false,
  ~expirePending: array<pendingExpiry>=[],
  ~corsRules: S3.Bucket.corsRules=defaultCorsRules,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
): ReventlessInfra.Platform.objectStore => {
  // A declared store is plugin substrate; the legacy hand-written store, which
  // names no plugin, stays platform-scoped so its tags are unchanged.
  let (kind, scope) = switch plugin {
  | Some(_) => (
      ReventlessCore.ComponentType.Plugin,
      ReventlessCore.ResourceAttribution.Scope.Plugin,
    )
  | None => (
      ReventlessCore.ComponentType.Platform,
      ReventlessCore.ResourceAttribution.Scope.Platform,
    )
  }

  let opts: Pulumi.CustomResourceOptions.t = {
    ...opts->Option.getOr({}),
    protect,
  }

  // Expire objects nobody ever claimed — the half of abandonment the release
  // path cannot reach, because the client that would have released them is
  // gone (tab closed, navigation, dead network).
  //
  // Filtered on the pending tag **and** this store's served prefix, never on
  // either alone, and written per store rather than once per bucket — a shared
  // bucket holds several stores, and expiring a neighbouring store's objects on
  // this store's setting would be exactly the wrong kind of surprise on a
  // bucket created with `protect: true`.
  //
  // What makes it safe is what it *cannot* match. An object minted before this
  // mechanism existed carries no tag; a claimed object has had its tag stripped.
  // Neither is inside the filter, so the rule's blast radius is precisely
  // "uploaded here, and no committed event references it". The one way it
  // deletes live data is a claim component that stopped and was not noticed —
  // which is why the claimer alarms on its own lag, why this is opt-in per
  // store, and why the plan sequences reconciliation before the first store
  // turns it on.
  let lifecycleRules = expirePending->Array.map(({prefix, days}) => {
    S3.Bucket.id: `reventless-pending-expiry-${prefix->String.replaceAll("/", "-")}`,
    enabled: true,
    prefix: `${prefix}/`,
    tags: Dict.fromArray([(Upload_PendingTag.key, Upload_PendingTag.value)]),
    expiration: {days: days},
  })

  let bucket = S3.Bucket.make(
    ~name,
    ~args={
      corsRules: corsRules->Pulumi.Input.make,
      forceDestroy: forceDestroy->Pulumi.Input.make,
      lifecycleRules: lifecycleRules->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name,
        ~kind,
        ~role=Other("ObjectStore"),
        ~scope,
        ~plugin?,
      ),
    },
    ~opts,
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
    keyPrefix,
  }
}

/** The same bucket, addressed under a different key prefix.

    A shared-layout stack puts every declared store in one bucket, so the bucket
    is created once and each store is that bucket seen through its own prefix.
    Splitting this out keeps the memoisation of "one bucket per physical name"
    separate from "one store per declaration", which are different cardinalities
    the moment a layout shares. */
let underPrefix = (
  store: ReventlessInfra.Platform.objectStore,
  ~keyPrefix: string,
): ReventlessInfra.Platform.objectStore => {...store, keyPrefix}
