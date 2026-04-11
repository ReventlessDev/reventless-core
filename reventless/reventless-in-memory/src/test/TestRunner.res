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

// Stop the shared GraphQL server started by Platform.Make().
// Call this in afterAll() to release the HTTP port.
let stopGraphQLServer = () => DomainGraphQL_Server.stop()

// Reset GraphQL server registry state.
// Call between test suites when creating multiple Platform.Make() instances.
let resetGraphQLServer = () => DomainGraphQL_Server.reset()

// Clear all active heartbeat timers started by HeartbeatRunner_InMemory.
// Call in afterAll when using Plugin_Builder with HeartbeatRunner_InMemory.
let resetHeartbeatRunner = () => HeartbeatRunner_InMemory.reset()

// ─────────────────────────────────────────────────────────────
// Bus test utilities
// ─────────────────────────────────────────────────────────────

type collectedEvent = {
  service: string,
  meta: ReventlessCore.Message.meta,
  json: JSON.t,
}

/**
 * Subscribe to topicName and return a promise that resolves once exactly n events
 * have been delivered by the bus.
 *
 * The subscription is registered synchronously (before the returned promise is
 * awaited), so events published immediately after calling collectNEvents are
 * captured. done_ is handled by the drain fiber automatically.
 *
 * Returns an empty array immediately if n <= 0.
 */
let collectNEvents = (
  subscribeToEvents: (
    string,
    (string, ReventlessCore.Message.meta, JSON.t) => promise<unit>,
  ) => unit,
  topicName: string,
  n: int,
): promise<array<collectedEvent>> => {
  if n <= 0 {
    Promise.resolve([])
  } else {
    let collected: ref<array<collectedEvent>> = ref([])
    let resolve: ref<option<array<collectedEvent> => unit>> = ref(None)
    // Promise.make callback runs synchronously — resolve is set before subscribeToEvents.
    let p = Promise.make((res, _) => {
      resolve := Some(res)
    })
    subscribeToEvents(topicName, async (service, meta, json) => {
      collected.contents->Array.push({service, meta, json})
      if Array.length(collected.contents) >= n {
        switch resolve.contents {
        | Some(f) => f(collected.contents)
        | None => ()
        }
      }
    })
    p
  }
}
