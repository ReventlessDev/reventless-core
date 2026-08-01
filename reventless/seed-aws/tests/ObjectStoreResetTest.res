// How the reset learns which uploaded objects belong to which plugin, and what
// it refuses.
//
// A declared store's bucket is built by the PLATFORM deploy, so its tags say
// which project built it, not whose data is in it. Ownership therefore comes
// from the platform's `objectStores` stack output, and these pin the pure half
// of that: parsing the output, and refusing any store set a prefix-scoped wipe
// could not separate. The impure half is a `pulumi stack output` subprocess and
// the S3 calls, and the decisions under test are in neither.

open JestGlobals

module Reset = ReventlessSeedAws_Reset

let obj = entries => JSON.Encode.object(entries->Dict.fromArray)
let str = JSON.Encode.string

let storeEntry = (~bucket, ~prefix) =>
  obj([("bucketName", str(bucket)), ("keyPrefix", str(prefix))])

let output = entries => Some(obj(entries))

let store = (~qualified, ~bucket, ~prefix): Reset.objectStore => {
  let (plugin, name) = Reset.splitQualified(qualified)->Option.getOr(("", qualified))
  {qualified, plugin, store: name, bucketName: bucket, keyPrefix: prefix}
}

describe("parseObjectStores", () => {
  testSync("splits the qualified key into plugin and store", () =>
    switch Reset.parseObjectStores(
      output([("Catalog.productImages", storeEntry(~bucket="alpha-stores", ~prefix="productImages"))]),
    ) {
    | Ok([s]) =>
      expect((s.plugin, s.store, s.bucketName, s.keyPrefix))->toEqual((
        "Catalog",
        "productImages",
        "alpha-stores",
        "productImages",
      ))
    | other => fail(`expected one parsed store, got ${other->JSON.stringifyAny->Option.getOr("?")}`)
    }
  )

  // A store name may contain a dot; a registered plugin name may not — so the
  // split is at the first one, matching how the key is composed.
  testSync("splits at the first dot only", () =>
    switch Reset.splitQualified("Catalog.product.images") {
    | Some((plugin, name)) => expect((plugin, name))->toEqual(("Catalog", "product.images"))
    | None => fail("expected a split")
    }
  )

  // A platform that declares no stores is ordinary, not an error.
  testSync("absent output yields no stores", () =>
    switch Reset.parseObjectStores(None) {
    | Ok(stores) => expect(stores->Array.length)->toBe(0)
    | Error(message) => fail(message)
    }
  )

  // A store the reset cannot read is a store it would silently leave behind, so
  // a malformed entry fails the run rather than being skipped.
  testSync("a malformed entry is an error, not a skip", () =>
    switch Reset.parseObjectStores(output([("Catalog.productImages", obj([("keyPrefix", str("x"))]))])) {
    | Ok(_) => fail("expected a malformed entry to be refused")
    | Error(message) => expect(message->String.includes("Catalog.productImages"))->toBe(true)
    }
  )

  testSync("an unqualified key is an error", () =>
    switch Reset.parseObjectStores(
      output([("productImages", storeEntry(~bucket="alpha-stores", ~prefix="productImages"))]),
    ) {
    | Ok(_) => fail("expected an unqualified key to be refused")
    | Error(message) => expect(message->String.includes("productImages"))->toBe(true)
    }
  )
})

describe("validateStores", () => {
  testSync("distinct prefixes in one bucket are fine", () =>
    expect(
      Reset.validateStores([
        store(~qualified="Catalog.productImages", ~bucket="alpha-stores", ~prefix="productImages"),
        store(~qualified="Ordering.labels", ~bucket="alpha-stores", ~prefix="labels"),
      ]),
    )->toEqual(Ok())
  )

  // The cross-plugin collision: one prefix, two owners, nothing to tell their
  // objects apart.
  testSync("two plugins on one prefix are refused", () =>
    switch Reset.validateStores([
      store(~qualified="Catalog.productImages", ~bucket="alpha-stores", ~prefix="productImages"),
      store(~qualified="Ordering.productImages", ~bucket="alpha-stores", ~prefix="productImages"),
    ]) {
    | Ok() => fail("expected a collision to be refused")
    | Error(message) =>
      expect(
        message->String.includes("Catalog.productImages") &&
          message->String.includes("Ordering.productImages"),
      )->toBe(true)
    }
  )

  // The same shape one level up: `Catalog` encloses `Catalog/productImages`, so
  // wiping the first would delete the second's objects.
  testSync("an enclosing prefix is refused", () =>
    switch Reset.validateStores([
      store(~qualified="Legacy.catalog", ~bucket="alpha-stores", ~prefix="Catalog"),
      store(~qualified="Catalog.productImages", ~bucket="alpha-stores", ~prefix="Catalog/productImages"),
    ]) {
    | Ok() => fail("expected an enclosing prefix to be refused")
    | Error(message) => expect(message->String.includes("encloses"))->toBe(true)
    }
  )

  // Different buckets cannot reach each other, so an equal prefix there is not a
  // collision — which is what the per-store layout produces in production.
  testSync("one prefix in two different buckets is fine", () =>
    expect(
      Reset.validateStores([
        store(~qualified="Catalog.productImages", ~bucket="catalog-productImages", ~prefix="productImages"),
        store(~qualified="Ordering.productImages", ~bucket="ordering-productImages", ~prefix="productImages"),
      ]),
    )->toEqual(Ok())
  )

  // A shared prefix that merely starts with another's characters is not nesting:
  // the delete prefix carries a trailing slash, so `images` cannot reach
  // `images-archive`.
  testSync("a sibling prefix sharing a character run is fine", () =>
    expect(
      Reset.validateStores([
        store(~qualified="Catalog.images", ~bucket="alpha-stores", ~prefix="images"),
        store(~qualified="Catalog.imagesArchive", ~bucket="alpha-stores", ~prefix="images-archive"),
      ]),
    )->toEqual(Ok())
  )

  testSync("an empty or slash-bearing store name is refused", () => {
    switch Reset.validateStores([
      store(~qualified="Catalog.productImages", ~bucket="alpha-stores", ~prefix=""),
    ]) {
    | Ok() => fail("expected an empty prefix to be refused")
    | Error(_) => ()
    }
    switch Reset.validateStores([
      store(~qualified="Catalog.a/b", ~bucket="alpha-stores", ~prefix="a/b"),
    ]) {
    | Ok() => fail("expected a store name containing a slash to be refused")
    | Error(_) => ()
    }
  })
})

describe("pluginOf", () => {
  // The `objectStores` keys carry the REGISTERED plugin name; the menu carries
  // the operator-facing label. Attribution uses the declared name so the reset
  // never has to guess the relation between the two.
  testSync("prefers the declared plugin name over the label", () =>
    expect(
      Reset.pluginOf({projectDir: "../catalog-aws", label: "catalog", group: Domain, plugin: "Catalog"}),
    )->toBe("Catalog")
  )

  testSync("falls back to the label when no plugin name is declared", () =>
    expect(Reset.pluginOf({projectDir: ".", label: "platform", group: Platform}))->toBe("platform")
  )
})
