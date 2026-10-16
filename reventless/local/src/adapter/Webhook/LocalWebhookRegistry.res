// The local platform's webhook routes, served in process: no HTTP server, so a
// test (or a dev tool) posts a raw body with `post`, which runs the same
// signature check and dispatch as the AWS Function URL.

open ReventlessCore

let slices: dict<InboundTranslationSlice_Webhook.slice> = Dict.make()

/** Register a slice's route now, and bind its operations when they resolve. A
    request posted before then waits for them rather than failing. Two slices may
    not share a path. */
let register = (
  ~route: InboundTranslationSlice_Webhook.route,
  ~operations: Pulumi.Output.t<ReventlessInfra.InboundTranslationSlice.operations>,
) => {
  switch slices->Dict.get(route.path) {
  | Some({route: taken}) =>
    JsError.throwWithMessage(
      `webhook path /${route.path} is declared by both ${taken.slice} and ${route.slice}`,
    )
  | None => ()
  }
  let bind = ref(_ => ())
  let bound: promise<ReventlessInfra.InboundTranslationSlice.operations> = Promise.make((
    resolve,
    _,
  ) => bind := resolve)
  let _ = operations->Pulumi.Output.apply(ops => bind.contents(ops))
  slices->Dict.set(
    route.path,
    {
      route,
      receive: async (input, ~caller) => await (await bound).receive(input, ~caller, ~door=Webhook),
      refuse: async (~body, ~errorCode, error) =>
        await (await bound).refuse(~body, ~errorCode, error),
    },
  )
}

/** Serve one request. Header names are matched case-insensitively. */
let post = (
  ~path: string,
  ~method: string="POST",
  ~headers: dict<string>=Dict.make(),
  ~secretOf=?,
  ~nowSeconds=?,
  body: string,
): promise<InboundTranslationSlice_Webhook.response> =>
  InboundTranslationSlice_Webhook.dispatch(
    slices->Dict.valuesToArray,
    ~secretOf?,
    ~nowSeconds?,
    {
      method,
      path,
      headers: headers
      ->Dict.toArray
      ->Array.map(((name, value)) => (name->String.toLowerCase, value))
      ->Dict.fromArray,
      body,
    },
  )

let reset = () => slices->Dict.keysToArray->Array.forEach(path => slices->Dict.delete(path))
