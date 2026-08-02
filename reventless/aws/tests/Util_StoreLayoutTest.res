open JestGlobals

let prodStacks = Util_HostUiDomain.defaultProdStacks

describe("Util_StoreLayout.layoutFor", () => {
  testSync("a prod-named stack gets a bucket per store", () =>
    expect(Util_StoreLayout.layoutFor(~stack="prod", ~prodStacks))->toEqual(Util_StoreLayout.PerStore)
  )

  testSync("'main' is production too, by the shared prod list", () =>
    expect(Util_StoreLayout.layoutFor(~stack="main", ~prodStacks))->toEqual(Util_StoreLayout.PerStore)
  )

  testSync("alpha shares one bucket", () =>
    expect(Util_StoreLayout.layoutFor(~stack="alpha", ~prodStacks))->toEqual(
      Util_StoreLayout.SharedBucket,
    )
  )

  testSync("a PR stack shares one bucket — the factor that multiplies", () =>
    expect(Util_StoreLayout.layoutFor(~stack="pr-1234", ~prodStacks))->toEqual(
      Util_StoreLayout.SharedBucket,
    )
  )

  // The accepted fail-open: a production stack whose name is not on the list
  // gets the weaker layout silently. Asserted so the behaviour is a decision on
  // record rather than a surprise, and so the config override is the documented
  // fix rather than a code change.
  testSync("an unlisted production name falls open to the shared layout", () =>
    expect(Util_StoreLayout.layoutFor(~stack="production", ~prodStacks))->toEqual(
      Util_StoreLayout.SharedBucket,
    )
  )

  testSync("adding it to the prod list is the fix", () =>
    expect(Util_StoreLayout.layoutFor(~stack="production", ~prodStacks=["prod", "production"]))->toEqual(
      Util_StoreLayout.PerStore,
    )
  )
})

describe("Util_StoreLayout.servingFor", () => {
  testSync("no declared store means nothing to serve", () =>
    expect(Util_StoreLayout.servingFor(~hasHostUiBundle=false, ~declaredBucketCount=0))->toEqual(
      Util_StoreLayout.NoStores,
    )
  )

  testSync("a host shell serves the stores from its own origin", () =>
    expect(Util_StoreLayout.servingFor(~hasHostUiBundle=true, ~declaredBucketCount=1))->toEqual(
      Util_StoreLayout.HostShell,
    )
  )

  // The case that was previously unrepresentable and produced a write-only
  // store: stores are provisioned unconditionally, but serving used to happen
  // only as a side car to a host-UI bundle.
  testSync("no host shell means the platform serves them itself", () =>
    expect(Util_StoreLayout.servingFor(~hasHostUiBundle=false, ~declaredBucketCount=1))->toEqual(
      Util_StoreLayout.PlatformOwned,
    )
  )

  // A bucket carries exactly one policy, so two distributions fronting one
  // store would unpick each other's read grant. The three-way return is what
  // makes "both" unrepresentable — asserted so it stays that way.
  testSync("a host shell wins even with several buckets — never both", () =>
    expect(Util_StoreLayout.servingFor(~hasHostUiBundle=true, ~declaredBucketCount=3))->toEqual(
      Util_StoreLayout.HostShell,
    )
  )

  // Declaring nothing outranks having a shell: with no store there is no
  // bucket, no policy and no origin, whoever is deployed.
  testSync("no store outranks a host shell", () =>
    expect(Util_StoreLayout.servingFor(~hasHostUiBundle=true, ~declaredBucketCount=0))->toEqual(
      Util_StoreLayout.NoStores,
    )
  )
})

describe("Util_StoreLayout.coverageFor", () => {
  testSync("everything declared is provisioned", () =>
    expect(
      Util_StoreLayout.coverageFor(
        ~required=["Catalog.productImages"],
        ~provisioned=["Catalog.productImages"],
      ),
    )->toEqual(Util_StoreLayout.Covered)
  )

  testSync("declaring nothing is covered, whatever the platform provisions", () =>
    expect(Util_StoreLayout.coverageFor(~required=[], ~provisioned=["Catalog.productImages"]))->toEqual(
      Util_StoreLayout.Covered,
    )
  )

  // A platform provisioning nothing has not adopted capability provisioning.
  // Failing it would break deployments that work today, so this is the arm that
  // must NOT be a hard error.
  testSync("a platform provisioning nothing has not adopted, rather than got it wrong", () =>
    expect(Util_StoreLayout.coverageFor(~required=["Catalog.productImages"], ~provisioned=[]))->toEqual(
      Util_StoreLayout.NotAdopted(["Catalog.productImages"]),
    )
  )

  // The case that shipped: the platform declared the store under a lowercased
  // plugin name, so both sides had a productImages store and neither matched.
  // It carries what IS provisioned because the cause is usually a near-miss.
  testSync("a near-miss reports both sides — this is the case-slip shape", () =>
    expect(
      Util_StoreLayout.coverageFor(
        ~required=["Catalog.productImages"],
        ~provisioned=["catalog.productImages"],
      ),
    )->toEqual(
      Util_StoreLayout.Missing({
        missing: ["Catalog.productImages"],
        provisioned: ["catalog.productImages"],
      }),
    )
  )

  testSync("only the uncovered stores are reported missing", () =>
    expect(
      Util_StoreLayout.coverageFor(
        ~required=["Catalog.productImages", "Catalog.manuals"],
        ~provisioned=["Catalog.productImages"],
      ),
    )->toEqual(
      Util_StoreLayout.Missing({
        missing: ["Catalog.manuals"],
        provisioned: ["Catalog.productImages"],
      }),
    )
  )

  // Matching is exact. Suffix or case-insensitive matching would "fix" the
  // case slip above by silently binding to the wrong store, and two plugins may
  // legitimately name a store the same.
  testSync("matching is exact — a suffix match is not a match", () =>
    expect(
      Util_StoreLayout.coverageFor(
        ~required=["Catalog.productImages"],
        ~provisioned=["Ordering.productImages"],
      ),
    )->toEqual(
      Util_StoreLayout.Missing({
        missing: ["Catalog.productImages"],
        provisioned: ["Ordering.productImages"],
      }),
    )
  )
})

describe("Util_StoreLayout.protectionFor", () => {
  // The pairing a single layout-driven switch would have got wrong: alpha
  // shares a bucket and is still protected.
  testSync("alpha shares a bucket and is still protected", () => {
    expect(Util_StoreLayout.layoutFor(~stack="alpha", ~prodStacks))->toEqual(
      Util_StoreLayout.SharedBucket,
    )
    expect(Util_StoreLayout.protectionFor(~stack="alpha"))->toEqual(Util_StoreLayout.Protected)
  })

  testSync("prod is protected", () =>
    expect(Util_StoreLayout.protectionFor(~stack="prod"))->toEqual(Util_StoreLayout.Protected)
  )

  testSync("a PR stack is unprotected so teardown does not leak buckets", () =>
    expect(Util_StoreLayout.protectionFor(~stack="pr-42"))->toEqual(Util_StoreLayout.Unprotected)
  )

  testSync("'prepare' is not a PR stack — the prefix is 'pr-', not 'pr'", () =>
    expect(Util_StoreLayout.protectionFor(~stack="prepare"))->toEqual(Util_StoreLayout.Protected)
  )
})

describe("Util_StoreLayout.bucketNameFor", () => {
  testSync("per-store names the bucket after the declaration", () =>
    expect(
      Util_StoreLayout.bucketNameFor(
        ~layout=PerStore,
        ~stack="prod",
        ~plugin="catalog",
        ~store="productImages",
      ),
    )->toBe("catalog-productImages")
  )

  testSync("shared names one bucket per stack", () =>
    expect(
      Util_StoreLayout.bucketNameFor(
        ~layout=SharedBucket,
        ~stack="alpha",
        ~plugin="catalog",
        ~store="productImages",
      ),
    )->toBe("alpha-stores")
  )

  testSync("every store on a shared stack lands in the same bucket", () =>
    expect(
      Util_StoreLayout.bucketNameFor(
        ~layout=SharedBucket,
        ~stack="alpha",
        ~plugin="ordering",
        ~store="invoices",
      ),
    )->toBe(
      Util_StoreLayout.bucketNameFor(
        ~layout=SharedBucket,
        ~stack="alpha",
        ~plugin="catalog",
        ~store="productImages",
      ),
    )
  )
})

describe("Util_StoreLayout.keyPrefixFor", () => {
  // The assertion the whole dual-layout scheme rests on: a ref is
  // layout-independent, so the same declaration produces the same stored string
  // on a per-store stack and a shared one. Plugin and store are both
  // stack-invariant, so qualifying by plugin keeps that property.
  testSync("the key prefix qualifies the store with its plugin", () =>
    expect(Util_StoreLayout.keyPrefixFor(~plugin="Catalog", ~store="productImages"))->toBe(
      "Catalog/productImages",
    )
  )

  // The reason it is qualified: the prefix is a platform-global namespace (one
  // distribution, one cache behavior per prefix), so two plugins declaring one
  // store name were unroutable in EITHER layout until the plugin qualified them.
  testSync("two plugins declaring one store name get distinct prefixes", () =>
    expect(
      Util_StoreLayout.keyPrefixFor(~plugin="Catalog", ~store="productImages") !=
        Util_StoreLayout.keyPrefixFor(~plugin="Ordering", ~store="productImages"),
    )->toBe(true)
  )
})

describe("Util_StoreLayout.pendingExpiryFor", () => {
  // The default is the whole point: expiry is the one step in the mechanism that
  // deletes objects, and it is only sound once reconciliation has confirmed the
  // tagged set is the unreferenced set. A store nobody named accumulates.
  testSync("no config at all means no store expires anything", () =>
    expect(
      Util_StoreLayout.pendingExpiryFor(~config=None, ~store="Catalog.productImages"),
    )->toEqual(None)
  )

  testSync("a store the config does not name expires nothing", () =>
    expect(
      Util_StoreLayout.pendingExpiryFor(
        ~config=Some("Ordering.receipts=14"),
        ~store="Catalog.productImages",
      ),
    )->toEqual(None)
  )

  testSync("a named store takes its own retention", () =>
    expect(
      Util_StoreLayout.pendingExpiryFor(
        ~config=Some("Catalog.productImages=30"),
        ~store="Catalog.productImages",
      ),
    )->toEqual(Some(30))
  )

  // Per store, one at a time — the plan's sequencing expressed in the setting.
  testSync("stores are enabled independently, with their own values", () => {
    let config = Some("Catalog.productImages=30, Ordering.receipts=14")
    expect((
      Util_StoreLayout.pendingExpiryFor(~config, ~store="Catalog.productImages"),
      Util_StoreLayout.pendingExpiryFor(~config, ~store="Ordering.receipts"),
      Util_StoreLayout.pendingExpiryFor(~config, ~store="Catalog.other"),
    ))->toEqual((Some(30), Some(14), None))
  })

  // Guessing at what a typo meant, in the one setting that deletes objects, is
  // not a service — an unreadable entry leaves the store accumulating.
  testSync("a malformed or non-positive entry is ignored, not defaulted", () => {
    let of_ = c => Util_StoreLayout.pendingExpiryFor(~config=Some(c), ~store="Catalog.productImages")
    expect((
      of_("Catalog.productImages"),
      of_("Catalog.productImages="),
      of_("Catalog.productImages=soon"),
      of_("Catalog.productImages=0"),
      of_("Catalog.productImages=-1"),
    ))->toEqual((None, None, None, None, None))
  })

  // The prefix is a platform-global namespace, so two plugins' stores are
  // distinct keys — enabling one must not enable the other.
  testSync("a store name is matched whole, not by prefix", () =>
    expect(
      Util_StoreLayout.pendingExpiryFor(
        ~config=Some("Catalog.productImages=30"),
        ~store="Catalog.productImagesArchive",
      ),
    )->toEqual(None)
  )
})
