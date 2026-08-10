// The runtime that `QueryInterception.use` puts in front of every DynamoDB-backed
// Query resolver — one pipeline step whose only job is to consult the hook.
//
// The hook is a module-level `ref`, and in a deployed runtime the only thing that
// ever fills it is a `RuntimeExtension`'s `onColdStart`. Every other runtime
// reaches those through a compiled entry shell that awaits `runtimeExtensionsReady`
// before it serves anything; this handler is not built by a shell, so it awaits
// the same promise itself. Without it the extensions the archive already carries
// are never imported, the hook stays `None`, and interception degrades to a
// passthrough that costs an invocation on every read and observes nothing — the
// one failure mode this path cannot afford, because it is silent and its whole
// price has already been paid.
//
// Awaited from the small module rather than from `HandlerFactoryHelpers`, which
// re-exports the same binding behind the Effect runtime and the DynamoDB clients:
// this runtime is sized for a decision, not for work.

type payload = {
  readModelName: string,
  arguments: JSON.t,
  identity: Reventless.Identity.t,
}

@module("../Runtime/RuntimeExtensionsReady.mjs")
external runtimeExtensionsReady: promise<unit> = "runtimeExtensionsReady"

let handler = async (event: payload, _context) => {
  await runtimeExtensionsReady
  switch ReventlessCore.QueryDb_Callback.queryInterceptorHook.contents {
  | None => true
  | Some(interceptor) =>
    switch await interceptor(
      ~identity=event.identity,
      ~readModelName=event.readModelName,
      ~args=event.arguments,
    ) {
    | Allow => true
    | Deny(msg) => JsError.throwWithMessage(msg)
    }
  }
}
