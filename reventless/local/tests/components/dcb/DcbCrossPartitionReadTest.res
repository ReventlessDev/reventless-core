// End-to-end proof of the inferred cross-partition read fix: a sibling product
// sharing the same categoryId must NOT be returned by AddProduct's decision read,
// because the categoryId clause indexes only the category's own events. Exercises
// the full command → narrowed query → in-memory DcbEventLog read → decide path
// that the unit tests and GWTs do not cover (the GWT harness folds events raw).

open JestGlobals
open DcbCrossPartitionFixtures

describe("DCB inferred cross-partition read (sibling exclusion)", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
  })

  let _ = beforeEach(() => {
    capturedEventCount := 0
  })

  testPromise(
    "a sibling product sharing the categoryId is not read; the new product is added",
    async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      // Category cat1 exists, and a DIFFERENT product p1 already lives in it
      // (tagged productId=p1 AND categoryId=cat1).
      let _ = await ops.append([
        encodeEvent(CategoryAdded({categoryId: "cat1", name: "Electronics"})),
        encodeEvent(ProductAdded({productId: "p1", categoryId: "cat1", name: "Laptop"})),
      ])
      capturedEventCount := 0 // count only events produced by the command below

      // Add a new product p2 in cat1. The categoryId clause narrows ProductAdded
      // out, so it reads only CategoryAdded — p1 is invisible — and p2 is added.
      await dispatch(addProductJson("p2", "cat1", "Mouse"), "p2")
      expect(capturedEventCount.contents)->toBe(1)
    },
  )

  testPromise(
    "a product added through the slice is NOT written to the categoryId GSI (payload, not indexed)",
    async () => {
      let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
      let _ = await ops.append([encodeEvent(CategoryAdded({categoryId: "cat3", name: "Toys"}))])
      // p3 is produced by the slice → its categoryId is filtered out on write.
      await dispatch(addProductJson("p3", "cat3", "Blocks"), "p3")

      // Queryable by its own partition key…
      let byProduct = await ops.read(~query=[{tags: [{Reventless.DcbTag.key: "productId", value: "p3"}]}])
      expect(byProduct.events->Array.some(e => e.eventType == "ProductAdded"))->toBe(true)

      // …but the categoryId index returns only the category's own event, never p3.
      let byCategory = await ops.read(~query=[{tags: [{Reventless.DcbTag.key: "categoryId", value: "cat3"}]}])
      expect(byCategory.events->Array.some(e => e.eventType == "ProductAdded"))->toBe(false)
      expect(byCategory.events->Array.some(e => e.eventType == "CategoryAdded"))->toBe(true)
    },
  )

  testPromise("re-adding the same product is still rejected (its own read is partition-scoped)", async () => {
    let ops = await eventLog->ReventlessCore.Component.operations->TestRunner.resolve
    let _ = await ops.append([
      encodeEvent(CategoryAdded({categoryId: "cat2", name: "Books"})),
      encodeEvent(ProductAdded({productId: "p9", categoryId: "cat2", name: "Novel"})),
    ])
    capturedEventCount := 0 // count only events produced by the command below
    // p9 already exists — its own productId clause returns its ProductAdded.
    await dispatch(addProductJson("p9", "cat2", "Novel"), "p9")
    expect(capturedEventCount.contents)->toBe(0)
  })
})
