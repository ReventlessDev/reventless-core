// Test utilities for reventless-in-memory.
// Call setup() once before any Platform.Make() in tests to activate Pulumi mock mode,
// which makes Output.apply resolve synchronously and ComponentResource constructors work.

// Pulumi mock interface
type mockArgs = {
  \"type": string,
  name: string,
  inputs: JSON.t,
}

type mockResult = {
  id: string,
  state: JSON.t,
}

@module("@pulumi/pulumi") @scope("runtime")
external setMocks: ({"newResource": mockArgs => mockResult, "call": mockArgs => JSON.t}) => unit =
  "setMocks"

// Activate Pulumi mock mode. Must be called once before any Platform.Make() or component creation.
let setup = () =>
  setMocks({
    "newResource": args => {
      id: args.name ++ "_id",
      state: args.inputs,
    },
    "call": args => args.inputs,
  })

// Resolve a Pulumi Output to a promise.
// In mock mode, the promise resolves immediately with the output value.
@send external promise: Pulumi.Output.t<'a> => promise<'a> = "promise"
let resolve = (output: Pulumi.Output.t<'a>): promise<'a> => output->promise
