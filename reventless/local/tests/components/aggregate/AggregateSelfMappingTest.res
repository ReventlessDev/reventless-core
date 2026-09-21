// Regression test for the event-mapping self-deadlock.
// See AggregateSelfMappingFixtures.res for the shape.
//
// Without the fix, publishing Place never returns: the mapper awaits the Ship
// it issues, and Ship's event waits for the mapper to dequeue it.

open TestFixtures
open JestGlobals
open AggregateSelfMappingFixtures

describe("Event mapping that commands its own source:", () => {
  let _ = beforeAllAsync(async () => {
    let _ = await agg->ShipmentAgg.operations->TestRunner.resolve
  })

  testPromise("Place returns, and the mapped Ship still runs", async () => {
    let ops = await agg->ShipmentAgg.operations->TestRunner.resolve
    let place = {
      Reventless.Message.id: "shipment-1",
      // The mapper finds its mappings by the event's service, as a real command's is.
      meta: {...testMeta, service: ShipmentSpec.name},
      commandJson: ShipmentSpec.Place->ReventlessCore.Message.encode(ShipmentSpec.commandSchema),
    }
    let outcome = await withTimeout(ops.publishJsons([place]), ~ms=1500)
    expect(
      switch outcome {
      | Ok(_) => "ok"
      | Error(msg) => msg
      },
    )->toBe("ok")

    // The Ship command is detached; let it run.
    let _ = await withTimeout(
      Promise.make(
        (resolve, _) => {
          let _ = setTimeout(() => resolve(), 100)
        },
      ),
      ~ms=1000,
    )
    expect(publishedEvents.contents)->toBe(2)
  })
})
