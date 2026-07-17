// Platform_Casts — typed identity coercions used by Platform.MakeWithConfig.
//
// Every cast here is a `%identity` external: zero runtime cost, the value passes
// through unchanged. The coercions are necessary because two independent
// architectural constraints prevent the type system from expressing the correct
// concrete type at the boundaries where these values flow.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY CASTS ARE NEEDED AT ALL
// ─────────────────────────────────────────────────────────────────────────────
//
// The Reventless package hierarchy is:
//
//   reventless-spec
//       └── reventless (core)
//               └── reventless-aws
//
// `reventless-core` defines the platform hook interface (`platformHooks`) that
// AWS, in-memory, and any future provider all implement. Because `reventless-core`
// sits *below* `reventless-aws` in the dependency graph, it cannot import AWS
// types such as `Util.Lambda.runtimeParts`, `DcbEventLog.component`, or
// `Util.SQS.channelParts`. Hook callbacks therefore use `unknown` (or a generic
// parameter) at the boundary where `reventless-core` hands values to the
// provider. The AWS platform is the only caller and always passes the right
// type, but the type system cannot see through the abstraction layer.
//
// The alternative — making `platformHooks` fully generic over every AWS-specific
// type — would thread extra type parameters through Plugin_Builder, Admin, and
// every functor that touches hooks. The type noise would dwarf the safety gain.
//
// ─────────────────────────────────────────────────────────────────────────────
// CAST 1 — runtime environment type parameter
// ─────────────────────────────────────────────────────────────────────────────
//
// `inboundAppSyncResolverParams` and `dcbAppSyncResolverParams` (defined in
// Plugin_Helpers.res) carry:
//
//   runtime: Runtime.environment<unknown>
//
// The hook boundary erases the concrete parts type to `unknown` because
// `reventless-core` cannot reference `Util.Lambda.runtimeParts`. At runtime
// the AWS platform always passes a genuine `Runtime.environment<runtimeParts>`,
// so narrowing the type parameter is safe.
//
// The "proper" fix — `inboundAppSyncResolverParams<'runtimeParts>` — would
// require propagating `'runtimeParts` through `platformHooks`, `Plugin_Builder`,
// and `Admin`.
external asLambdaRuntime: ReventlessCore.Runtime.environment<unknown> => ReventlessCore.Runtime.environment<Util.Lambda.runtimeParts> = "%identity"

// ─────────────────────────────────────────────────────────────────────────────
// CAST 2 — hook callback arguments (unknown → concrete component types)
// ─────────────────────────────────────────────────────────────────────────────
//
// The deployment lifecycle hooks in `platformHooks`:
//
//   onDcbEventLogCreated?:       unknown => unit
//   onDcbCommandTopicCreated?:   unknown => unit
//   onDcbSlicesCreated?:         unknown => unit
//   onHeartbeatEpChannelAvailable?: (unknown, ~pluginId: string) => unit
//
// are typed `unknown => unit` for the same dependency-inversion reason as above:
// `reventless-core` cannot import `DcbEventLog.component`, `CommandTopic.component`,
// or `CommandTopic_Adapter.remoteChannel`. The AWS platform registers these
// callbacks and is the only caller, always passing the correct concrete value.
external asDcbEventLogComponent: unknown => ReventlessCore.Component.t<unit, ReventlessCore.DcbEventLog.outputs, unit> = "%identity"
external asDcbCommandTopicComponent: unknown => ReventlessCore.CommandTopic.component<unit> = "%identity"
external asDcbEventLog: unknown => ReventlessCore.DcbEventLog.component = "%identity"
external asRemoteChannel: unknown => ReventlessCore.CommandTopic_Adapter.remoteChannel = "%identity"

// ─────────────────────────────────────────────────────────────────────────────
// CAST 3 — generic adapter channel parts
// ─────────────────────────────────────────────────────────────────────────────
//
// `CommandTopic_Adapter.channel` carries:
//
//   parts: 'channelParts   (generic — provider fills this in)
//
// The adapter interface is provider-agnostic so the field is left generic.
// The AWS adapter always stores a `Util.SQS.channelParts` value there.
// Threading `'channelParts` through the adapter interface and all its callers
// would be a large, noisy change for a single specialisation.
external asSqsChannelParts: 'a => Util.SQS.channelParts = "%identity"

// ─────────────────────────────────────────────────────────────────────────────
// CAST 4 — Pulumi Output Proxy vs. ReScript option boxing
// ─────────────────────────────────────────────────────────────────────────────
//
// This cast is categorically different: it is a *runtime hazard*, not a type
// system limitation.
//
// `Pulumi.Output.t<'a>` values are ES6 Proxy objects. ReScript's option encoding
// uses a sentinel property `BS_PRIVATE_NESTED_SOME_NONE` to distinguish
// `Some(Some(x))` from `Some(x)`. When a Proxy is placed directly inside
// `Some(pulumiOutput)`, the Proxy intercepts the sentinel property lookup and
// can return an unexpected result, silently corrupting the None/Some distinction
// at runtime.
//
// The `{val: x}` wrapper (`hookedValue<unknown>`) avoids this by never placing
// the Proxy directly in the option slot. The concrete type is recovered via
// `Obj.magic` in `Plugin_Builder` where the provider-specific type is known.
//
// There is no type-level fix because the problem does not exist at the type
// level — it is a mismatch between ReScript's JS boxing convention and Pulumi's
// Proxy-based lazy evaluation model.
external _toUnknown: 'a => unknown = "%identity"
let wrapHookedValue: 'a => ReventlessCore.Plugin_Helpers.hookedValue<unknown> = x => {val: x->_toUnknown}
