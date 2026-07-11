// LocalGraphQL_SubscriptionResolvers.res
// In-process wiring of the local event bus into the promoted, transport-neutral
// GraphQL subscription bridge (`ReventlessGraphqlServer.GraphQL_SubscriptionBridge`).
//
// The generic pieces — topic naming, the field-resolver builder, `registerAll`,
// and the `@aws_subscribe` stripping — live in core-adjacent
// `GraphQL_SubscriptionBridge`, parameterized over a PubSub instance. This
// module supplies the in-process `GraphqlYoga.createPubSub()` singleton and the
// Bus→PubSub glue that is specific to the local in-process backend:
//
// Source A (raw event stream): subscribes to Bus.subscribeToEvents for each event log
//   topic and publishes the event envelope to a yoga PubSub channel.
//
// Source B (state changes): subscribes to Bus.subscribeToStateChanges for each QueryDb
//   and publishes saved state items to a yoga PubSub channel.
//
// Source C (mutation-triggered): mutation resolvers would need to publish to the PubSub
//   after each successful command. This is left as future work — currently mutations do
//   not cross-post to the subscription PubSub in-memory.
//
// Usage: wire the bridges (bridgeSourceA / bridgeSourceB), then `registerAll` to
//   wire subscriptions into the GraphQL server instance. Both must be called
//   before the server starts.

module YG = GraphqlYoga
module Bridge = ReventlessGraphqlServer.GraphQL_SubscriptionBridge

// ── PubSub instance ───────────────────────────────────────────────────────────
// The single in-process PubSub used by every local server. Cross-process
// delivery is not a concern in-memory, so this is byte-identical to the pre-
// promotion behavior: one process, one PubSub, topics disambiguate channels.

let pubSub: ref<option<YG.pubSub>> = ref(None)

let getPubSub = () =>
  switch pubSub.contents {
  | Some(ps) => ps
  | None =>
    let ps = YG.createPubSub()
    pubSub.contents = Some(ps)
    ps
  }

// ── Topic naming (re-exported from the promoted bridge) ────────────────────────

let sourceATopic = Bridge.sourceATopic
let sourceBTopic = Bridge.sourceBTopic

// ── Bridge: Bus → PubSub ──────────────────────────────────────────────────────

/** Wire Source A: subscribe to event bus topic → publish to yoga PubSub channel. */
let bridgeSourceA = (
  ~subscribeToEvents: (
    string,
    (string, ReventlessCore.Message.meta, JSON.t) => promise<unit>,
  ) => unit,
  ~displayName: string,
  ~busTopicName: string,
) => {
  let ps = getPubSub()
  let yogaTopic = sourceATopic(displayName)
  // Push the raw event JSON directly — it already contains the event data.
  // In-memory events don't carry a separate position envelope.
  subscribeToEvents(busTopicName, async (_service, _meta, json) => {
    ps->YG.pubSubPublish(yogaTopic, json)
  })
}

/** Wire Source B: subscribe to state-change hook → publish to yoga PubSub channel. */
let bridgeSourceB = (
  ~subscribeToStateChanges: (string, JSON.t => unit) => unit,
  ~readModelName: string,
  ~returnTypeName: string,
) => {
  let ps = getPubSub()
  let yogaTopic = sourceBTopic(returnTypeName)
  subscribeToStateChanges(readModelName, state => {
    ps->YG.pubSubPublish(yogaTopic, state)
  })
}

// ── Subscription resolver builder (delegates to the promoted bridge) ───────────

let makeFieldResolver = (topic: string): YG.resolverFn =>
  Bridge.makeFieldResolver(~pubSub=getPubSub(), topic)

// ── Public API (delegates to the promoted bridge, binding the local PubSub) ────

type subscriptionEntry = Bridge.subscriptionEntry = {
  fieldName: string,
  topic: string,
}

/**
 * Register subscriptions with the GraphQL server instance.
 *
 * `sourceAEntries`: list of {fieldName, topic} for Source A (event stream).
 *   Bridge must already be wired via bridgeSourceA before calling this.
 *
 * `sourceBEntries`: list of {fieldName, topic} for Source B (state changes).
 *   Bridge must already be wired via bridgeSourceB before calling this.
 *
 * `sdlFields`: the `subscriptions` SDL field strings from the plugin fragment
 *   (after stripping `@aws_subscribe` directives — not valid in yoga).
 */
let registerAll = (
  ~server: ReventlessGraphqlServer.GraphQL_ServerInstance.t,
  ~sdlFields: array<string>,
  ~sourceAEntries: array<subscriptionEntry>,
  ~sourceBEntries: array<subscriptionEntry>,
) => Bridge.registerAll(~server, ~sdlFields, ~sourceAEntries, ~sourceBEntries, ~pubSub=getPubSub())

/** Publish a payload to a named PubSub topic (for Source C mutation resolvers). */
let publish = (topic: string, payload: JSON.t) =>
  Bridge.publish(~pubSub=getPubSub(), topic, payload)

let reset = () => {
  pubSub.contents = None
}
