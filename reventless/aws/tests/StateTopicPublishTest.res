// Unit tests for the Postgres live-update publisher (B3.3a).
//
// `withLiveUpdates` wraps a Postgres QueryDb ops set so save/delete also publish
// an AppSync-Events change descriptor. The publish itself (SigV4 POST) is
// injected here as a capturing stub, so this exercises the WRAPPING logic
// headlessly — entity-key composition, changeKind, sortKeyValue extraction, the
// `option<(field,subValue)>` delete signature, and composite partition-wide
// delete enumeration via ops.load. The real SigV4/channel wire format matches
// StateTopic_AppSync (the DynamoDB path) by construction and is not re-asserted
// here.

open JestGlobals

// Drive a scenario against withLiveUpdates with a mock ops + capturing publish,
// entirely in JS (the mock ops are plain JS objects). Returns the captured
// publish-call array as JSON for assertions.
let run: string => promise<JSON.t> = %raw(`
async function(scenario) {
  const mod = await import("../src/adapter/Runtime/StateTopicPublish.mjs");
  const { withLiveUpdates, makeDescriptor } = mod;
  const captured = [];
  // Record the descriptor the real publisher would build alongside the call, with
  // a fixed seq so assertions stay deterministic. sortKeyValue/state derivation
  // lives in makeDescriptor, so this keeps it under test at the wrapper level.
  const publish = async (call) => {
    captured.push({ ...call, descriptor: makeDescriptor({ ...call, seq: "1" }) });
  };
  const ok = async () => ({ TAG: "Ok", _0: undefined });

  // Mock ops. load returns the composite partition's rows for the enumerate case.
  const partitionRows = { TAG: "Ok", _0: [
    { id: "o1", lineId: "L1" },
    { id: "o1", lineId: "L2" },
  ]};
  const ops = {
    load: async (id) => partitionRows,
    loadStream: () => {},
    save: ok, saveBatch: ok, count: ok, delete: ok, deleteBatch: ok,
  };

  const cfg = (subIdField) => ({
    endpoint: "https://x.appsync-api.eu-west-1.amazonaws.com",
    region: "eu-west-1",
    topicName: "Shop_Orders",
    subIdField,
    publish,
  });

  const w = (subIdField) => withLiveUpdates(ops, cfg(subIdField));

  switch (scenario) {
    case "save-single":
      await w(undefined).save("p1", { id: "p1", updatedAt: "2024-01-02" }, "Insert", undefined);
      break;
    case "save-composite":
      await w("lineId").save("o1", { id: "o1", lineId: "L2", createdAt: "2024-03-04" }, "Insert", undefined);
      break;
    case "save-no-sortkey":
      await w(undefined).save("p1", { id: "p1" }, "Insert", undefined);
      break;
    case "save-oversized":
      await w(undefined).save("p1", { id: "p1", blob: "x".repeat(70 * 1024) }, "Insert", undefined);
      break;
    case "saveBatch":
      await w(undefined).saveBatch([
        ["a", { id: "a", updatedAt: "t1" }, undefined],
        ["b", { id: "b", updatedAt: "t2" }, undefined],
      ]);
      break;
    case "delete-single":
      await w(undefined).delete("p1", undefined);
      break;
    case "delete-composite-row":
      await w("lineId").delete("o1", ["lineId", "L2"]);
      break;
    case "delete-composite-partition":
      await w("lineId").delete("o1", undefined);
      break;
    case "deleteBatch":
      await w(undefined).deleteBatch([["a", undefined], ["b", undefined]]);
      break;
    case "gated-no-topic": {
      const gatedOps = withLiveUpdates(ops, { endpoint: "https://x", region: "r", topicName: undefined, publish });
      await gatedOps.save("p1", { id: "p1" }, "Insert", undefined);
      break;
    }
  }
  return captured;
}
`)

let getField = (call: JSON.t, key: string): option<JSON.t> =>
  call->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))

let str = (call, key) => getField(call, key)->Option.flatMap(JSON.Decode.string)

let descriptorField = (call: JSON.t, key: string): option<JSON.t> =>
  getField(call, "descriptor")->Option.flatMap(d => getField(d, key))

let descriptorStr = (call, key) => descriptorField(call, key)->Option.flatMap(JSON.Decode.string)

let calls = (j: JSON.t): array<JSON.t> => j->JSON.Decode.array->Option.getOr([])

describe("withLiveUpdates (B3.3a Postgres live updates)", () => {
  testAsync("save on a single-key table publishes Updated with sortKeyValue", async () => {
    let c = await run("save-single")
    let arr = calls(c)
    expect(arr->Array.length)->toBe(1)
    let call = arr->Array.getUnsafe(0)
    expect(str(call, "entityKey"))->toEqual(Some("p1"))
    expect(str(call, "changeKind"))->toEqual(Some("Updated"))
    expect(descriptorStr(call, "sortKeyValue"))->toEqual(Some("2024-01-02"))
    expect(str(call, "topicName"))->toEqual(Some("Shop_Orders"))
    // The saved row rides along so a subscriber can apply it without refetching.
    expect(descriptorField(call, "state"))->toEqual(getField(call, "state"))
    expect(descriptorStr(call, "seq"))->toEqual(Some("1"))
  })

  testAsync("save on a composite table uses id-subKey and createdAt fallback", async () => {
    let c = await run("save-composite")
    let call = calls(c)->Array.getUnsafe(0)
    expect(str(call, "entityKey"))->toEqual(Some("o1-L2"))
    expect(str(call, "changeKind"))->toEqual(Some("Updated"))
    expect(descriptorStr(call, "sortKeyValue"))->toEqual(Some("2024-03-04"))
  })

  testAsync("save without updatedAt/createdAt omits sortKeyValue", async () => {
    let c = await run("save-no-sortkey")
    let call = calls(c)->Array.getUnsafe(0)
    expect(descriptorField(call, "sortKeyValue"))->toEqual(None)
  })

  testAsync("an oversized row degrades to a metadata-only descriptor", async () => {
    let c = await run("save-oversized")
    let call = calls(c)->Array.getUnsafe(0)
    expect(descriptorField(call, "state"))->toEqual(None)
    expect(descriptorStr(call, "changeKind"))->toEqual(Some("Updated"))
    expect(descriptorStr(call, "seq"))->toEqual(Some("1"))
  })

  testAsync("saveBatch publishes one Updated per item", async () => {
    let c = await run("saveBatch")
    let arr = calls(c)
    expect(arr->Array.length)->toBe(2)
    expect(str(arr->Array.getUnsafe(0), "entityKey"))->toEqual(Some("a"))
    expect(str(arr->Array.getUnsafe(1), "entityKey"))->toEqual(Some("b"))
    arr->Array.forEach(call => expect(str(call, "changeKind"))->toEqual(Some("Updated")))
  })

  testAsync("delete on a single-key table publishes Removed for the id", async () => {
    let c = await run("delete-single")
    let call = calls(c)->Array.getUnsafe(0)
    expect(str(call, "entityKey"))->toEqual(Some("p1"))
    expect(str(call, "changeKind"))->toEqual(Some("Removed"))
  })

  testAsync("delete of a specific composite row uses id-subValue", async () => {
    let c = await run("delete-composite-row")
    let arr = calls(c)
    expect(arr->Array.length)->toBe(1)
    expect(str(arr->Array.getUnsafe(0), "entityKey"))->toEqual(Some("o1-L2"))
    expect(str(arr->Array.getUnsafe(0), "changeKind"))->toEqual(Some("Removed"))
  })

  testAsync("partition-wide composite delete enumerates rows via load", async () => {
    let c = await run("delete-composite-partition")
    let arr = calls(c)
    expect(arr->Array.length)->toBe(2)
    expect(str(arr->Array.getUnsafe(0), "entityKey"))->toEqual(Some("o1-L1"))
    expect(str(arr->Array.getUnsafe(1), "entityKey"))->toEqual(Some("o1-L2"))
    arr->Array.forEach(call => expect(str(call, "changeKind"))->toEqual(Some("Removed")))
  })

  testAsync("deleteBatch publishes one Removed per entry", async () => {
    let c = await run("deleteBatch")
    let arr = calls(c)
    expect(arr->Array.length)->toBe(2)
    expect(str(arr->Array.getUnsafe(0), "entityKey"))->toEqual(Some("a"))
    expect(str(arr->Array.getUnsafe(1), "entityKey"))->toEqual(Some("b"))
  })

  testAsync("no topicName → ops pass through, nothing published", async () => {
    let c = await run("gated-no-topic")
    expect(calls(c)->Array.length)->toBe(0)
  })
})
