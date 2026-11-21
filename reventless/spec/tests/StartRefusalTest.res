open JestGlobals

// A refused start is a value with a code and its fields; the sentence people read is
// made from it, and the error a refused start throws carries it.

let contradiction = StartRefusal.PartitionContradiction({
  slice: "MoveContact",
  named: "contactId",
  inference: Derives("partyId"),
  arms: [],
})

describe("StartRefusal.message", () => {
  testSync("a partition contradiction reads as the build has always said it", () =>
    expect(StartRefusal.message({component: "Relationships", refusals: [contradiction]}))->toBe(
      "DCB partition contradiction (Relationships): MoveContact: @partitionTag names contactId, but inference derives partyId from the slice graph — contactId is read from another entity. Remove the annotation, or move it to partyId.",
    )
  )

  testSync("several findings are joined by slice", () => {
    let unreachable = StartRefusal.PartitionUnreachable({
      slice: "QuestionState",
      named: "messageId",
      missed: ["ReplyPosted"],
    })
    expect(
      StartRefusal.message({component: "Forum", refusals: [contradiction, unreachable]}),
    )->toBe(
      "DCB partition contradiction (Forum): MoveContact: @partitionTag names contactId, but inference derives partyId from the slice graph — contactId is read from another entity. Remove the annotation, or move it to partyId. | QuestionState: @partitionTag messageId decides the partition, but ReplyPosted carry messageId and are stored under another key, so the slice's read by messageId never finds them. Partition their writers by messageId, or mark messageId @crossPartition on ReplyPosted in the slice's consumedEvent to read it across partitions.",
    )
  })

  testSync("a contradiction among candidates names them, and the arms a marker would reach", () =>
    expect(
      StartRefusal.describe(
        PartitionContradiction({
          slice: "ShipOrder",
          named: "orderId",
          inference: Candidates(["carrierBookingId"]),
          arms: ["WarehouseAssigned"],
        }),
      ),
    )->toBe(
      "@partitionTag names orderId, which this slice only reads as a reference to another entity (candidates: carrierBookingId). Move the annotation to the slice's own key, or mark orderId @crossPartition on WarehouseAssigned in the slice's consumedEvent to read it across partitions.",
    )
  )

  testSync("the other kinds keep their sentences", () => {
    expect(
      StartRefusal.message({
        component: "Forum",
        refusals: [
          ScopeContradiction({
            slice: "QuestionState",
            eventType: "ReplyPosted",
            marked: "channelId",
            partition: "messageId",
          }),
        ],
      }),
    )->toBe(
      "DCB scope contradiction (Forum): QuestionState: ReplyPosted marks channelId @crossPartition, but QuestionState is partitioned by messageId. A consumed arm marks only the slice's own key; a read of another entity's channelId across partitions follows from the slice graph, or from @crossPartition on the event that writes it. Remove the marker.",
    )
    expect(
      StartRefusal.message({refusals: [NoPartitionKey({slice: "Join", reason: "two keys"})]}),
    )->toBe("DCB partition key cannot be inferred — Join: two keys")
    expect(
      StartRefusal.message({
        refusals: [StoreInUse({path: "/app/local.db", app: "shop", port: 4000, pid: 42})],
      }),
    )->toBe(
      "refusing to reset /app/local.db: it is the store of shop running at :4000 (pid 42). Stop that platform first, or start this one without ?reset.",
    )
    expect(
      StartRefusal.message({
        refusals: [RoleUnhonoured({plugin: "Shop", role: "Shopper", why: "is self-service"})],
      }),
    )->toBe(
      "Admission this platform cannot honor — the people it is for could not get in:\n  Shop: Shopper is self-service",
    )
  })
})

describe("StartRefusal.toJson", () => {
  testSync("says the code, the component, the slice and both keys", () =>
    expect(StartRefusal.toJson({component: "Relationships", refusals: [contradiction]}))->toEqual(
      %raw(`{
        message: "DCB partition contradiction (Relationships): MoveContact: @partitionTag names contactId, but inference derives partyId from the slice graph — contactId is read from another entity. Remove the annotation, or move it to partyId.",
        component: "Relationships",
        refusals: [{
          code: "partition-contradiction",
          message: "@partitionTag names contactId, but inference derives partyId from the slice graph — contactId is read from another entity. Remove the annotation, or move it to partyId.",
          slice: "MoveContact",
          named: "contactId",
          derived: "partyId",
          arms: [],
        }],
      }`),
    )
  )

  testSync("an error without a refusal is coded unknown", () =>
    expect(StartRefusal.unknownToJson("boom"))->toEqual(
      %raw(`{message: "boom", refusals: [{code: "unknown", message: "boom"}]}`),
    )
  )
})

describe("StartRefusal.ofError", () => {
  testSync("reads back the refusal the error carries, under its message", () => {
    let refusal: StartRefusal.t = {component: "Relationships", refusals: [contradiction]}
    switch StartRefusal.throw(refusal) {
    | () => fail("expected a throw")
    | exception JsExn(e) =>
      expect(e->JsExn.message)->toEqual(Some(StartRefusal.message(refusal)))
      expect(StartRefusal.ofError(e))->toEqual(Some(refusal))
    }
  })

  testSync(
    "finds none on an error that carries none, or on a thrown value that is no error",
    () => {
      let none = thrown =>
        switch JsExn.throw(thrown) {
        | () => None
        | exception JsExn(e) => StartRefusal.ofError(e)
        }
      expect(none(JsError.make("plain")))->toEqual(None)
      expect(none("a string"))->toEqual(None)
      expect(none(Nullable.null))->toEqual(None)
      expect(none(%raw(`{refusal: {refusals: "not a list"}}`)))->toEqual(None)
    },
  )
})
