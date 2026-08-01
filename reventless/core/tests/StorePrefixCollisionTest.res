open JestGlobals

// The rule these guard is that a store's key prefix is a PLATFORM-global
// namespace: one distribution fronts every store bucket and takes one cache
// behavior per prefix, so two stores on one prefix are unroutable whatever the
// bucket layout. Left to the deploy that surfaces as a CloudFront error about a
// path pattern, minutes in and naming neither plugin.

module Collision = StorePrefixCollision

let store = (~qualified, ~prefix, ~site=?): Collision.declaredStore => {
  qualified,
  prefix,
  ?site,
}

describe("collisionsFor", () => {
  testSync("distinct prefixes do not collide", () =>
    expect(
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="Catalog.productImages", ~prefix="productImages"),
          store(~qualified="Ordering.labels", ~prefix="labels"),
        ],
      )->Array.length,
    )->toBe(0)
  )

  testSync("two plugins declaring one store name collide", () =>
    switch Collision.collisionsFor(
      ~stores=[
        store(~qualified="Catalog.productImages", ~prefix="productImages"),
        store(~qualified="Ordering.productImages", ~prefix="productImages"),
      ],
    ) {
    | [c] => expect((c.first.qualified, c.second.qualified, c.nested))->toEqual((
        "Catalog.productImages",
        "Ordering.productImages",
        false,
      ))
    | other => fail(`expected exactly one collision, got ${other->Array.length->Int.toString}`)
    }
  )

  // Deliberate cross-plugin sharing resolves to ONE qualified key upstream, so
  // it never reaches this predicate as two stores. Sharing is legitimate; only
  // two independent claims on one prefix are not.
  testSync("one store referenced by several plugins is a single entry, not a collision", () =>
    expect(
      Collision.collisionsFor(
        ~stores=[store(~qualified="Catalog.productImages", ~prefix="productImages")],
      )->Array.length,
    )->toBe(0)
  )

  // Containment, not equality: a store rooted at `a` encloses one at `a/b` for
  // serving, for upload grants and for a store wipe alike.
  testSync("an enclosing prefix collides with what it encloses", () =>
    switch Collision.collisionsFor(
      ~stores=[
        store(~qualified="Catalog.productImages", ~prefix="Catalog/productImages"),
        store(~qualified="Legacy.catalog", ~prefix="Catalog"),
      ],
    ) {
    | [c] =>
      // The enclosing store is reported first whichever order they arrive in.
      expect((c.first.qualified, c.nested))->toEqual(("Legacy.catalog", true))
    | other => fail(`expected exactly one collision, got ${other->Array.length->Int.toString}`)
    }
  )

  // A shared character run is not nesting — the delete/serve boundary is a path
  // segment, so `images` does not reach `images-archive`.
  testSync("a sibling prefix sharing a character run does not collide", () =>
    expect(
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="Catalog.images", ~prefix="images"),
          store(~qualified="Catalog.imagesArchive", ~prefix="images-archive"),
        ],
      )->Array.length,
    )->toBe(0)
  )

  // This is the property that lets a plugin-qualified prefix scheme relax the
  // rule without the predicate changing: qualified prefixes simply stop
  // colliding, so "unique per platform" narrows to "unique per plugin".
  testSync("qualifying the prefix with the plugin removes the collision", () =>
    expect(
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="Catalog.productImages", ~prefix="Catalog/productImages"),
          store(~qualified="Ordering.productImages", ~prefix="Ordering/productImages"),
        ],
      )->Array.length,
    )->toBe(0)
  )

  testSync("each colliding pair is reported once, not twice", () =>
    expect(
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="A.images", ~prefix="images"),
          store(~qualified="B.images", ~prefix="images"),
          store(~qualified="C.images", ~prefix="images"),
        ],
      )->Array.length,
    )->toBe(3)
  )
})

describe("collisionMessage", () => {
  testSync("names both stores and both remedies", () => {
    let message =
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="Catalog.productImages", ~prefix="productImages"),
          store(~qualified="Ordering.productImages", ~prefix="productImages"),
        ],
      )
      ->Array.get(0)
      ->Option.mapOr("", Collision.collisionMessage)
    expect(
      message->String.includes("Catalog.productImages") &&
      message->String.includes("Ordering.productImages") &&
      message->String.includes("Rename one store") &&
      message->String.includes("@storageRef"),
    )->toBe(true)
  })

  // Without provenance the message must not invent a declaration site; it points
  // at the file that does record one.
  testSync("points at the capability file when it has no declaration site", () => {
    let message =
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="A.images", ~prefix="images"),
          store(~qualified="B.images", ~prefix="images"),
        ],
      )
      ->Array.get(0)
      ->Option.mapOr("", Collision.collisionMessage)
    expect(message->String.includes("capability file"))->toBe(true)
  })

  testSync("uses the declaration site when the caller has one", () => {
    let message =
      Collision.collisionsFor(
        ~stores=[
          store(~qualified="A.images", ~prefix="images", ~site="Product.imageUrl"),
          store(~qualified="B.images", ~prefix="images", ~site="Shipment.imageUrl"),
        ],
      )
      ->Array.get(0)
      ->Option.mapOr("", Collision.collisionMessage)
    expect(
      message->String.includes("Product.imageUrl") && message->String.includes("Shipment.imageUrl"),
    )->toBe(true)
  })
})
