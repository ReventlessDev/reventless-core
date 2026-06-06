// E2E test: a DCB StateChangeSlice's events flow through the DcbEventLog's
// EventTopic and land in a ReadModel projection — the very pattern Plan 03
// is meant to enable.
//
// This test will silently pass-but-project-nothing if the Phase 1.5 fix
// (meta.service = `<name>DcbEventLog`) ever regresses, so it doubles as a
// regression vehicle for that fix.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect
open DcbReadModelE2EFixtures

describe("DCB → ReadModel E2E:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await dcbEventLog->DcbLogMaker.operations->TestRunner.resolve
    let _ = await rm->ProductsReadModel.operations->TestRunner.resolve
    // Wait for the ReadModel's EventCollector to register its bus subscription.
    let resource = dcbTopicOutputs.resources->Array.getUnsafe(0)
    let _ = await resource.name->TestRunner.resolve
  })

  testPromise("AddProduct command updates the ReadModel state", async () => {
    await dispatch(addProductCmd("prod-1", "Laptop"), "prod-1")
    let states = await loadState("prod-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.productId)->toBe("prod-1")
    expect(state.name)->toBe("Laptop")
  })

  testPromise("second AddProduct for the same id is a no-op (decide returns Error)", async () => {
    await dispatch(addProductCmd("prod-1", "Different name"), "prod-1")
    let states = await loadState("prod-1")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Laptop")
  })

  testPromise("a different product id gets its own entry", async () => {
    await dispatch(addProductCmd("prod-2", "Headphones"), "prod-2")
    let states = await loadState("prod-2")
    expect(states->Array.length)->toBe(1)
    let state = states->Array.getUnsafe(0)
    expect(state.name)->toBe("Headphones")
  })
})
