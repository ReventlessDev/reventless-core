open JestGlobals

// The automations' Lambda names the DCB command Lambda it invokes, and asks for it
// before the plugin builds it, inside a callback a preview skips where its inputs
// are unknown (a new stack). The wait must end there with the name unknown, not
// stay open: an open wait fails the whole preview.

type mockArgs = {@as("type") type_: string, name: string}
type mockResult = {id: string, state: JSON.t}

@module("@pulumi/pulumi") @scope("runtime")
external setMocks: (
  {"newResource": mockArgs => mockResult, "call": mockArgs => JSON.t},
  string,
  string,
  bool,
) => unit = "setMocks"

// The engine's unknown-during-preview Output, built the way the engine builds it.
@module("@pulumi/pulumi") @new
external makeOutput: (
  Set.t<unit>,
  promise<unit>,
  promise<bool>,
  promise<bool>,
  promise<Set.t<unit>>,
) => Pulumi.Output.t<unit> = "Output"

let unknownGate = () =>
  makeOutput(
    Set.make(),
    Promise.resolve(),
    Promise.resolve(false),
    Promise.resolve(false),
    Promise.resolve(Set.make()),
  )

@get external isKnown: Pulumi.Output.t<'a> => promise<bool> = "isKnown"
@send external valueOf: Pulumi.Output.t<'a> => promise<'a> = "promise"

type outcome<'a> = Settled('a) | StillWaiting

// What an output comes to, or that it has not come to anything after a while.
let within = async (p: promise<'a>) =>
  await Promise.race([
    p->Promise.thenResolve(v => Settled(v)),
    Promise.make((resolve, _) => {
      let _ = setTimeout(() => resolve(StillWaiting), 500)
    }),
  ])

let lambdaNamed = (name): Pulumi.Output.t<PulumiAws.Lambda.Function.t> =>
  Pulumi.Output.make({
    PulumiAws.Lambda.Function.arn: `arn:aws:lambda:eu-west-1:123456789012:function:${name}`->Pulumi.Output.make,
    id: name->Pulumi.Output.make,
    name: name->Pulumi.Output.make,
    invokeArn: "arn:aws:apigateway:invoke"->Pulumi.Output.make,
    lastModified: "2026-01-01T00:00:00.000+0000"->Pulumi.Output.make,
  })

beforeAll(() =>
  setMocks(
    {
      "newResource": args => {id: args.name ++ "_id", state: JSON.Encode.object(Dict.make())},
      "call": _ => JSON.Encode.object(Dict.make()),
    },
    "reventless-test",
    "test",
    true,
  )
)

describe("DcbCommandFunctions.functionFor in a preview", () => {
  test("a new stack: the plugin's callback cannot run, the name is unknown", async () => {
    let commandFunction = DcbCommandFunctions.functionFor("new-stack-queue"->Pulumi.Output.make)
    DcbCommandFunctions.gate(unknownGate())

    expect(await within(commandFunction->isKnown))->toEqual(Settled(false))
    expect(DcbCommandFunctions.waiters->Array.length)->toBe(0)
  })

  test("an existing stack: the callback runs and names the function", async () => {
    let queueUrl = "existing-stack-queue"->Pulumi.Output.make
    let commandFunction = DcbCommandFunctions.functionFor(queueUrl)
    let inputs = Pulumi.Output.make()
    DcbCommandFunctions.gate(inputs)
    let _ =
      inputs->Pulumi.Output.apply(
        () =>
          DcbCommandFunctions.register(
            ~queueUrl,
            ~name="CatalogDcbCmdHandler",
            ~lambda=lambdaNamed("CatalogDcbCmdHandler-1a2b"),
          ),
      )

    expect(await within(commandFunction->valueOf))->toEqual(Settled("CatalogDcbCmdHandler-1a2b"))
  })

  test("a command topic whose Lambda was not built names none", async () => {
    let queueUrl = "no-function-queue"->Pulumi.Output.make
    let commandFunction = DcbCommandFunctions.functionFor(queueUrl)
    let inputs = Pulumi.Output.make()
    DcbCommandFunctions.gate(inputs)
    let _ = inputs->Pulumi.Output.apply(() => DcbCommandFunctions.noFunction(~queueUrl))

    expect(await within(commandFunction->valueOf))->toEqual(Settled(""))
  })

  test("a queue settled before it is asked for answers at once", async () => {
    let queueUrl = "settled-queue"->Pulumi.Output.make
    DcbCommandFunctions.noFunction(~queueUrl)

    expect(await within(DcbCommandFunctions.functionFor(queueUrl)->valueOf))->toEqual(Settled(""))
  })
})
