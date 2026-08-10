// The runtime that `QueryInterception.use` puts in front of every DynamoDB-backed
// Query resolver — one pipeline step whose only job is to consult the hook.
//
// The hook is a module-level `ref`, and in a deployed runtime the only thing that
// ever fills it is a `RuntimeExtension`'s `onColdStart`. So the handler awaits
// `runtimeExtensionsReady` before reading it. Without that the extensions the
// archive already carries are never imported, the hook stays `None`, and
// interception degrades to a passthrough that costs an invocation on every read
// and observes nothing — the one failure mode this path cannot afford, because it
// is silent and its whole price has already been paid.
//
// The await is kept here even though `QueryInterceptorEntryPoint.mjs` now awaits
// the same promise at top level, because the two are answering different
// questions. The shell's await decides WHEN the seam fires — init rather than
// invoke, which is what keeps the load off the read path. This one is the
// module's own contract: it does not consult a hook it has not waited for,
// however it was entered. On the path they share, the second await is a settled
// promise and costs a microtask.
//
// Awaited from the small module rather than from `HandlerFactoryHelpers`, which
// re-exports the same binding behind the Effect runtime and the DynamoDB clients:
// there is no reason to pull that graph in to reach one promise.

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
