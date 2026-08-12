// Runtime-safe resolver error hook.
//
// Fires when a generateCommand resolver receives a command type that cannot be
// decoded against the registered command schema. Fire-and-forget: the hook
// returns unit, async work is the consumer's concern.
//
// Extracted from Plugin_Helpers so the Lambda runtime path (which calls into
// CommandGenerator_Callback) doesn't transitively import Plugin_Helpers' Pulumi
// dependencies.

type resolverErrorInfo = {
  pluginName: string,
  componentName: string,
  /** The GraphQL mutation field / command topic tag that was attempted. */
  attemptedCommandType: string,
  timestamp: string,
}

let onResolverErrorHook: ref<option<resolverErrorInfo => unit>> = ref(None)

let registerOnResolverError = (hook: resolverErrorInfo => unit) => {
  onResolverErrorHook.contents = Some(hook)
}

let clearOnResolverError = () => {
  onResolverErrorHook.contents = None
}

// ── Caller-fault errors ──────────────────────────────────────────────────────
//
// A failure a transport may report to the caller verbatim, because it describes
// the caller's own request: a payload that does not decode against the command
// schema, a caller who cannot be identified for a command that records an owner.
//
// It needs marking because the transports below deliberately hide everything
// else. graphql-yoga's `maskedErrors` answers `Unexpected error /
// INTERNAL_SERVER_ERROR` for any thrown value that is not a `GraphQLError`,
// which is right for a driver failure — an internal error is not the caller's
// business, and its message may not be theirs to read either. It is wrong for
// the two cases above: the server knows precisely what is wrong with the request
// and answers with the one thing the caller cannot act on.
//
// The mark rides on the error's `name` rather than a wrapper type, so it
// survives the `Effect` boundary, the `promise` boundary and the transports'
// `Obj.magic` interop unchanged, and an adapter that knows nothing about it
// keeps treating the error exactly as it does today.
let callerFaultName = "ReventlessCallerFault"

@set external setErrorName: (JsError.t, string) => unit = "name"

/** Throw a failure that describes the caller's own request. */
let throwCallerFault = (message: string): 'a => {
  let error = JsError.make(message)
  error->setErrorName(callerFaultName)
  error->JsError.throw
}

/** Whether a caught failure is one a transport may report verbatim.

    Matched as a substring because a command is generated inside an `Effect`, and
    a failure crossing `runPromise` comes back re-wrapped with the original name
    carried into the wrapper's — `(FiberFailure) ReventlessCallerFault`. The mark
    is a name, not a message, so nothing else can put it there. */
let isCallerFault = (exn: exn): bool =>
  exn
  ->JsExn.fromException
  ->Option.flatMap(JsExn.name)
  ->Option.mapOr(false, name => name->String.includes(callerFaultName))
