// The local platform's webhook routes. A test posts a raw body with `post`; a stand-in or a
// tool posts over HTTP to `/webhooks/<path>` on the domain server, which hands the bytes to
// `post`. Either way the same signature check and dispatch run as on the AWS Function URL.

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

/** The doors registered so far, by path: what a caller needs to post to each. */
let doors = (): array<InboundTranslationSlice_Webhook.route> =>
  slices->Dict.valuesToArray->Array.map(s => s.route)

/** The names of the secrets the signed doors are checked with, each once. */
let signedSecrets = (): array<string> =>
  doors()
  ->Array.filterMap(r =>
    switch r.auth {
    | SignedBody({secret}) => Some(secret)
    | Open => None
    }
  )
  ->Array.reduce([], (seen, n) => seen->Array.includes(n) ? seen : [...seen, n])

let reset = () => slices->Dict.keysToArray->Array.forEach(path => slices->Dict.delete(path))
