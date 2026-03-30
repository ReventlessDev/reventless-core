type payload = {
  readModelName: string,
  arguments: JSON.t,
  identity: Reventless.Identity.t,
}

let handler = async (event: payload, _context) => {
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
