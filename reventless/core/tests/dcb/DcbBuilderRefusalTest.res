// When the DCB build refuses to start, the error it throws carries the refusal as a value, and
// the error it logs carries the same value as the record's `detail`.

open JestGlobals

module DSI = Reventless.DcbScopeInference
module StartRefusal = Reventless.StartRefusal

let scal = (name): DSI.idField => {name, isList: false}
let cross = (name): DSI.idField => {name, isList: false, declared: true, crossPartition: true}
let ev = (eventType, idFields): DSI.eventShape => {eventType, idFields}

// `AddProduct` reads the category's lifecycle, so `categoryId` is a reference.
let addProduct: DSI.sliceShape = {
  sliceName: "AddProduct",
  command: [scal("productId"), scal("categoryId")],
  consumed: [ev("ProductAdded", [scal("productId")]), ev("CategoryAdded", [scal("categoryId")])],
  produced: [ev("ProductAdded", [scal("productId"), scal("categoryId")])],
  partitionHint: Some("categoryId"),
}
let addCategory: DSI.sliceShape = {
  sliceName: "AddCategory",
  command: [scal("categoryId")],
  consumed: [ev("CategoryAdded", [])],
  produced: [ev("CategoryAdded", [scal("categoryId")])],
  partitionHint: None,
}

let refusalOf = (f: unit => unit): option<StartRefusal.t> =>
  switch f() {
  | () => None
  | exception JsExn(e) => StartRefusal.ofError(e)
  }

/** Runs `f` at a log level that lets errors through, and keeps every record logged. */
let logged = (f: unit => unit): array<Logger.record> => {
  let records = []
  let previous = NodeProcess.env->Dict.get("LOG_LEVEL")
  NodeProcess.env->Dict.set("LOG_LEVEL", "error")
  let remove = Logger.addSink(r => records->Array.push(r))
  switch f() {
  | () => ()
  | exception _ => ()
  }
  remove()
  switch previous {
  | Some(v) => NodeProcess.env->Dict.set("LOG_LEVEL", v)
  | None => NodeProcess.env->Dict.delete("LOG_LEVEL")
  }
  records
}

let contradiction: StartRefusal.t = {
  component: "Catalog",
  refusals: [
    PartitionContradiction({
      slice: "AddProduct",
      named: "categoryId",
      inference: Derives("productId"),
      arms: [],
    }),
  ],
}

describe("Dcb_Builder.checkPartitionHints", () => {
  testSync("throws the contradiction as a refusal, under the message it always had", () => {
    let check = () =>
      Dcb_Builder.checkPartitionHints(~component="Catalog", ~shapes=[addProduct, addCategory])
    expect(refusalOf(check))->toEqual(Some(contradiction))
    switch check() {
    | () => fail("expected a throw")
    | exception JsExn(e) =>
      expect(e->JsExn.message)->toEqual(
        Some(
          "DCB partition contradiction (Catalog): AddProduct: @partitionTag names categoryId, but inference derives productId from the slice graph — categoryId is read from another entity. Remove the annotation, or move it to productId.",
        ),
      )
    }
  })

  testSync("lets an app whose hints agree go on", () =>
    expect(
      refusalOf(
        () =>
          Dcb_Builder.checkPartitionHints(
            ~component="Catalog",
            ~shapes=[{...addProduct, partitionHint: None}, addCategory],
          ),
      ),
    )->toEqual(None)
  )

  testSync("logs the refusal as the error record's detail", () => {
    let records = logged(
      () =>
        Dcb_Builder.checkPartitionHints(~component="Catalog", ~shapes=[addProduct, addCategory]),
    )
    let errors = records->Array.filter(r => r.level == Error)
    expect(errors->Array.map(r => r.message))->toEqual([StartRefusal.message(contradiction)])
    expect(
      errors->Array.map(
        r => r->Logger.recordToJson->JSON.Decode.object->Option.flatMap(o => o->Dict.get("detail")),
      ),
    )->toEqual([Some(StartRefusal.toJson(contradiction))])
  })
})

describe("Dcb_Builder.checkCrossPartitionArms", () => {
  testSync("throws a marker on another key than the slice's own as a scope refusal", () => {
    // The question is kept per message; a marker by the channel says nothing it could act on.
    let postMessage: DSI.sliceShape = {
      sliceName: "PostMessage",
      command: [],
      consumed: [],
      produced: [ev("MessagePosted", [scal("messageId"), scal("channelId")])],
      partitionHint: Some("messageId"),
    }
    let questionState: DSI.sliceShape = {
      sliceName: "QuestionState",
      command: [],
      consumed: [
        ev("MessagePosted", [scal("messageId"), scal("channelId")]),
        ev("ReplyPosted", [scal("replyId"), cross("messageId"), cross("channelId")]),
      ],
      produced: [ev("QuestionReopened", [scal("messageId"), scal("channelId")])],
      partitionHint: Some("messageId"),
    }
    let shapes = [postMessage, questionState]
    expect(
      refusalOf(
        () =>
          Dcb_Builder.checkCrossPartitionArms(
            ~component="Forum",
            ~shapes,
            ~inferred=DSI.infer(shapes),
          ),
      ),
    )->toEqual(
      Some({
        StartRefusal.component: "Forum",
        refusals: [
          StartRefusal.ScopeContradiction({
            slice: "QuestionState",
            eventType: "ReplyPosted",
            marked: "channelId",
            partition: "messageId",
          }),
        ],
      }),
    )
  })
})

describe("Dcb_Builder.deriveBoundaryPartition", () => {
  testSync("names the component in the refusal of a slice with no partition key", () => {
    // A pure join: two keys, both foreign, and nothing to tell them apart.
    module Join = {
      @schema
      type command = Join({aId: string, bId: string})
      @schema
      type consumedEvent = AHappened({aId: string}) | BHappened({bId: string})
      @schema
      type event =
        | Joined({
            aId: @s.matches(Reventless.DcbTag.string) string,
            bId: @s.matches(Reventless.DcbTag.string) string,
          })
    }
    let slice: Reventless.DcbTag.sliceSchemas = {
      name: "Join",
      commandSchema: Join.commandSchema->S.castToUnknown,
      consumedEventSchema: Join.consumedEventSchema->S.castToUnknown,
      eventSchema: Join.eventSchema->S.castToUnknown,
      moduleUrl: "",
    }
    let refused = switch refusalOf(
      () => {
        let _ = Dcb_Builder.deriveBoundaryPartition(~component="Joins", [slice])
      },
    ) {
    | Some({component: "Joins", refusals: [NoPartitionKey({slice: "Join"})]}) => true
    | _ => false
    }
    expect(refused)->toBe(true)
  })
})
