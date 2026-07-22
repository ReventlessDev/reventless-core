// Unit tests for DcbEventLogStorage_InMemory.
// Covers append, read (with filtering), headPosition, and conditional append.

open JestGlobals

let _ = TestRunner.setup()

let opts: Pulumi.CustomResourceOptions.t = {}

let makeStorage = () =>
  DcbEventLogStorage_InMemory.make(
    ~name="test-dcb",
    ~indexes=[],
    ~partitionTag=Reventless.DcbTag.Simple({key: "itemId"}),
    ~opts,
  )

let makeEvent = (~eventType, ~data, ~tags=[]): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data,
  tags,
  meta: ReventlessCore.Message.generateMeta(~service="test"),
}

describe("DcbEventLogStorage_InMemory", () => {
  describe("append", () => {
    testPromise("stores events and returns incrementing position", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let result1 = await ops.append([makeEvent(~eventType="ItemCreated", ~data=JSON.Null)])
      let result2 = await ops.append([makeEvent(~eventType="ItemUpdated", ~data=JSON.Null)])
      expect(result1)->toEqual(Ok("1"))
      expect(result2)->toEqual(Ok("2"))
    })

    testPromise("appending multiple events at once returns position of last event", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let result = await ops.append([
        makeEvent(~eventType="A", ~data=JSON.Null),
        makeEvent(~eventType="B", ~data=JSON.Null),
      ])
      expect(result)->toEqual(Ok("2"))
    })
  })

  describe("read", () => {
    testPromise("empty query returns all events", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(~eventType="Evt1", ~data=JSON.Null),
        makeEvent(~eventType="Evt2", ~data=JSON.Null),
      ])
      let result = await ops.read(~query=[])
      expect(result.events->Array.length)->toBe(2)
    })

    testPromise("filters by eventType", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(~eventType="Created", ~data=JSON.Null),
        makeEvent(~eventType="Updated", ~data=JSON.Null),
        makeEvent(~eventType="Created", ~data=JSON.Null),
      ])
      // Optional record fields use direct value syntax (not Some(...))
      let result = await ops.read(
        ~query=[{Reventless.DcbTag.eventTypes: ["Created"]}],
      )
      expect(result.events->Array.length)->toBe(2)
      let firstEvent = result.events->Array.getUnsafe(0)
      expect(firstEvent.eventType)->toBe("Created")
    })

    testPromise("filters by tags", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(
          ~eventType="Evt",
          ~data=JSON.Null,
          ~tags=[{Reventless.DcbTag.key: "tenant", value: "acme"}],
        ),
        makeEvent(~eventType="Evt", ~data=JSON.Null, ~tags=[]),
      ])
      let result = await ops.read(
        ~query=[
          {
            Reventless.DcbTag.tags: [{Reventless.DcbTag.key: "tenant", value: "acme"}],
          },
        ],
      )
      expect(result.events->Array.length)->toBe(1)
      let firstEvent = result.events->Array.getUnsafe(0)
      expect(firstEvent.tags->Array.length)->toBe(1)
    })

    testPromise("multi-tag clause matches only events carrying ALL tags", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(
          ~eventType="Evt",
          ~data=JSON.Null,
          ~tags=[{Reventless.DcbTag.key: "tenant", value: "acme"}, {key: "region", value: "eu"}],
        ),
        makeEvent(~eventType="Evt", ~data=JSON.Null, ~tags=[{Reventless.DcbTag.key: "tenant", value: "acme"}]),
        makeEvent(~eventType="Evt", ~data=JSON.Null, ~tags=[{Reventless.DcbTag.key: "region", value: "eu"}]),
      ])
      // Intersection of the two tags' posting lists → only the first event.
      let result = await ops.read(
        ~query=[
          {
            Reventless.DcbTag.tags: [
              {Reventless.DcbTag.key: "tenant", value: "acme"},
              {key: "region", value: "eu"},
            ],
          },
        ],
      )
      expect(result.events->Array.length)->toBe(1)
    })

    testPromise("OR of clauses unions matches across clauses in position order", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(~eventType="A", ~data=JSON.Null),
        makeEvent(~eventType="B", ~data=JSON.Null, ~tags=[{Reventless.DcbTag.key: "x", value: "1"}]),
        makeEvent(~eventType="C", ~data=JSON.Null),
      ])
      // Clause 1 (type A) ∪ clause 2 (tag x=1) → events at positions 1 and 2.
      let result = await ops.read(
        ~query=[
          {Reventless.DcbTag.eventTypes: ["A"]},
          {Reventless.DcbTag.tags: [{Reventless.DcbTag.key: "x", value: "1"}]},
        ],
      )
      expect(result.events->Array.length)->toBe(2)
      expect((result.events->Array.getUnsafe(0)).eventType)->toBe("A")
      expect((result.events->Array.getUnsafe(1)).eventType)->toBe("B")
    })

    // An empty tag value is a legitimate model state — an absent member of a
    // composite partition key. Every backend must accept it, record it verbatim,
    // and keep matching the event through its partition and composite reads. See
    // docs/plans/dcb-empty-tag-values-break-append.md.
    testPromise("an empty tag value appends and stays readable", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let tags = [
        {Reventless.DcbTag.key: "itemId", value: "i1"},
        {Reventless.DcbTag.key: "variantId", value: ""},
      ]
      let appended = await ops.append([makeEvent(~eventType="ItemAdded", ~data=JSON.Null, ~tags)])
      expect(appended)->toEqual(Ok("1"))

      let byPartition = await ops.read(
        ~query=[{Reventless.DcbTag.tags: [{Reventless.DcbTag.key: "itemId", value: "i1"}]}],
      )
      expect(byPartition.events->Array.length)->toBe(1)
      // The empty value is recorded verbatim, not dropped or substituted.
      expect((byPartition.events->Array.getUnsafe(0)).tags->Array.map(t => (t.key, t.value)))
      ->toEqual([("itemId", "i1"), ("variantId", "")])

      let byComposite = await ops.read(~query=[{Reventless.DcbTag.tags: tags}])
      expect(byComposite.events->Array.length)->toBe(1)
    })

    testPromise("after parameter skips events at or before that position", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(~eventType="E1", ~data=JSON.Null),
        makeEvent(~eventType="E2", ~data=JSON.Null),
        makeEvent(~eventType="E3", ~data=JSON.Null),
      ])
      let result = await ops.read(~query=[], ~after="1")
      // Events at position > "1" — positions 2 and 3
      expect(result.events->Array.length)->toBe(2)
      let firstEvent = result.events->Array.getUnsafe(0)
      expect(firstEvent.eventType)->toBe("E2")
    })
  })

  describe("headPosition", () => {
    testPromise("equals the position of the last appended event", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([
        makeEvent(~eventType="E1", ~data=JSON.Null),
        makeEvent(~eventType="E2", ~data=JSON.Null),
      ])
      let result = await ops.read(~query=[])
      expect(result.headPosition)->toEqual(Some("2"))
    })

    testPromise("headPosition is absent when no events have been stored", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let result = await ops.read(~query=[])
      expect(result.headPosition)->toEqual(None)
    })
  })

  describe("conditional append", () => {
    testPromise("append with matching condition query returns Error (conflict)", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([makeEvent(~eventType="ItemCreated", ~data=JSON.Null)])
      let condition: Reventless.DcbTag.appendCondition = {
        query: [{Reventless.DcbTag.eventTypes: ["ItemCreated"]}],
      }
      let result = await ops.append(
        [makeEvent(~eventType="ItemUpdated", ~data=JSON.Null)],
        ~condition,
      )
      expect(
        switch result {
        | Error(_) => true
        | Ok(_) => false
        },
      )->toBe(true)
    })

    testPromise("append with condition that matches no events succeeds", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      let _ = await ops.append([makeEvent(~eventType="OtherEvent", ~data=JSON.Null)])
      let condition: Reventless.DcbTag.appendCondition = {
        query: [{Reventless.DcbTag.eventTypes: ["ItemCreated"]}],
      }
      let result = await ops.append(
        [makeEvent(~eventType="ItemCreated", ~data=JSON.Null)],
        ~condition,
      )
      expect(result)->toEqual(Ok("2"))
    })

    testPromise("condition with after only checks events after that position", async () => {
      let storage = makeStorage()
      let ops = await storage.operations->TestRunner.resolve
      // Position 1: ItemCreated
      let _ = await ops.append([makeEvent(~eventType="ItemCreated", ~data=JSON.Null)])
      // Condition checks for ItemCreated only AFTER position "1" — no such events
      let condition: Reventless.DcbTag.appendCondition = {
        query: [{Reventless.DcbTag.eventTypes: ["ItemCreated"]}],
        after: "1",
      }
      let result = await ops.append(
        [makeEvent(~eventType="ItemUpdated", ~data=JSON.Null)],
        ~condition,
      )
      // No conflict because ItemCreated is at position 1, not > 1
      expect(result)->toEqual(Ok("2"))
    })
  })
})
