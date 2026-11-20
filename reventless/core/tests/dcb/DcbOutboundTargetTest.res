// An outbound slice naming an aggregate publishes through that aggregate's topic. The
// publishers are Pulumi Outputs, which answer every property read, so a choice that
// unwrapped one from an option handed the slice a nested `None` instead.

open JestGlobals

let published = ref([])
let toAggregate: CommandTopic.publishJsons = async jsons =>
  published := published.contents->Array.concat(jsons->Array.map(_ => "aggregate"))
let toDcb: CommandTopic.publishJsons = async jsons =>
  published := published.contents->Array.concat(jsons->Array.map(_ => "dcb"))

let publishers = Dict.fromArray([("Customer", toAggregate->Pulumi.Output.make)])
let fallback = toDcb->Pulumi.Output.make

let resolve = (output: Pulumi.Output.t<'a>): promise<'a> =>
  Promise.make((done, _) => {
    let _ = output->Pulumi.Output.apply(value => done(value))
  })

let meta: Message.meta = {
  service: "test",
  time: "2026-01-01T00:00:00Z",
  ip: "127.0.0.1",
  user: "test-user",
  msgId: "msg-1",
  correlationId: "corr-1",
}

let send = async targetName => {
  published := []
  let publish = await Dcb_Builder.publisherFor(~targetName, publishers, ~fallback)->resolve
  await publish([{Message.id: "c-1", meta, commandJson: JSON.Null}])
  published.contents
}

describe("Dcb_Builder.publisherFor", () => {
  testPromise("a slice naming an aggregate publishes to it", async () => {
    expect(await send(Some("Customer")))->toEqual(["aggregate"])
  })

  testPromise("a slice naming no aggregate publishes to the DCB topic", async () => {
    expect((await send(Some("Registrations")), await send(None)))->toEqual((["dcb"], ["dcb"]))
  })
})
