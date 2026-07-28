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
  // on a per-store stack and a shared one.
  testSync("the key prefix is the store name in both layouts", () =>
    expect(Util_StoreLayout.keyPrefixFor(~store="productImages"))->toBe("productImages")
  )
})
