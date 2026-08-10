open JestGlobals

// Guards the preview-unknown decoupling in `EventCollectorChannel_Helpers.connectLambda`.
//
// The collector's role policy and its event-source mappings used to be created
// inside ONE `Pulumi.Output.all3` apply over three unrelated input sets. Pulumi
// skips an apply whose inputs are unknown, and a resource the program never
// registers reads as a DELETE — so a single unknown input removed all of them
// from the preview, including mappings that never read it. That is how switching
// a plugin's slices to the stream builder deleted the plugin's event-log mapping:
// the new view tables' computed `streamArn` is unknown in the preview that
// enables it, and the view tables shared the apply with everything else.
//
// These tests drive `connectLambda` under Pulumi's mock runtime in preview mode
// with a genuinely unknown view-table resource, and assert the two resources that
// do not depend on it are still registered.

// ── Pulumi mock runtime ──────────────────────────────────────────────────────

type mockArgs = {@as("type") type_: string, name: string}
type mockResult = {id: string, state: JSON.t}

@module("@pulumi/pulumi") @scope("runtime")
external setMocks: (
  {"newResource": mockArgs => mockResult, "call": mockArgs => JSON.t},
  string,
  string,
  bool,
) => unit = "setMocks"

// The engine's unknown-during-preview Output: resolved, but flagged not-known, so
// `.apply` never fires while the value is still accepted as a resource INPUT.
// Constructed the way the engine does rather than faked with a pending promise —
// a promise that never settles would also stall resource registration, which is
// the very difference under test.
@module("@pulumi/pulumi") @new
external makeOutput: (
  Set.t<unit>,
  promise<'a>,
  promise<bool>,
  promise<bool>,
  promise<Set.t<unit>>,
) => Pulumi.Output.t<'a> = "Output"

let unknown = (): Pulumi.Output.t<'a> =>
  makeOutput(
    Set.make(),
    Promise.resolve(%raw(`undefined`)),
    Promise.resolve(false),
    Promise.resolve(false),
    Promise.resolve(Set.make()),
  )

let registered: array<(string, string)> = []

beforeAll(() =>
  setMocks(
    {
      "newResource": args => {
        registered->Array.push((args.type_, args.name))
        {id: args.name ++ "_id", state: JSON.Encode.object(Dict.make())}
      },
      "call": _ => JSON.Encode.object(Dict.make()),
    },
    "reventless-test",
    "test",
    true,
  )
)

// Pulumi registers resources asynchronously; give the runtime a few ticks.
let settle = async () => await Promise.make((resolve, _) => {
  let _ = setTimeout(() => resolve(), 300)
})

let wasRegistered = (type_, name) =>
  registered->Array.some(((t, n)) => t == type_ && n == name)

// ── Fixtures ─────────────────────────────────────────────────────────────────

// A view table whose fields never become known — what a QueryDb stream resource
// looks like in the preview that first enables its stream.
let unknownViewTable = ReventlessInfra.Adapter.make(
  ~name=unknown(),
  ~id=unknown(),
  ~urn=unknown(),
  ~service=unknown(),
  ~resourceInfo=unknown(),
)

// A known event-log stream — the ESM source. Unaffected by the slice switch.
let knownEventLogStream = ReventlessInfra.Adapter.make(
  ~name="CatalogDcbEventLog-abc123"->Pulumi.Output.make,
  ~id="stream-id"->Pulumi.Output.make,
  ~urn="arn:aws:dynamodb:eu-west-1:123456789012:table/CatalogDcbEventLog-abc123/stream/2026-01-01T00:00:00.000"->Pulumi.Output.make,
  ~service=AWS.DynamoDbStream.service->Pulumi.Output.make,
  ~resourceInfo=ReventlessInfra.Adapter.StreamSource({
    sourceUrn: "arn:aws:dynamodb:eu-west-1:123456789012:table/CatalogDcbEventLog-abc123/stream/2026-01-01T00:00:00.000",
  })->Pulumi.Output.make,
)

let lambdaRole: PulumiAws.IAM.Role.t = {
  arn: "arn:aws:iam::123456789012:role/AllStateViewSlicesRole"->Pulumi.Output.make,
  name: "AllStateViewSlicesRole"->Pulumi.Output.make,
  id: "AllStateViewSlicesRole"->Pulumi.Output.make,
}

let lambda: Pulumi.Output.t<PulumiAws.Lambda.Function.t> = Pulumi.Output.make({
  PulumiAws.Lambda.Function.arn: "arn:aws:lambda:eu-west-1:123456789012:function:AllStateViewSlices"->Pulumi.Output.make,
  id: "AllStateViewSlices"->Pulumi.Output.make,
  name: "AllStateViewSlices"->Pulumi.Output.make,
  invokeArn: "arn:aws:apigateway:invoke"->Pulumi.Output.make,
})

// ── Tests ────────────────────────────────────────────────────────────────────

describe("EventCollectorChannel_Helpers.connectLambda under an unknown view table", () => {
  let name = "AllStateViewSlices"

  beforeAllAsync(async () => {
    let _ = EventCollectorChannel_Helpers.connectLambda(
      lambda,
      name,
      lambdaRole,
      [],
      Dict.fromArray([("DcbEventLog", {ReventlessInfra.EventTopic.resources: [knownEventLogStream]})]),
      [unknownViewTable],
      {},
    )
    await settle()
  })

  test("still registers the collector's role policy", async () => {
    // The policy DOCUMENT genuinely depends on the unknown table, but the policy
    // RESOURCE must not: an unknown input previews as "value unknown", whereas an
    // unregistered resource previews as a delete.
    expect(wasRegistered("aws:iam/rolePolicy:RolePolicy", name))->toBe(true)
  })

  test("still registers the event-log mapping, which never reads a view table", async () => {
    expect(wasRegistered("aws:lambda/eventSourceMapping:EventSourceMapping", "CatalogDcbEventLog2" ++ name))->toBe(true)
  })
})
