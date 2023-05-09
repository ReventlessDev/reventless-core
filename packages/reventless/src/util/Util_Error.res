type t = {code: string, message: string}

@deprecated("now supported by standard library")
external ofPromise: Js.Promise.error => t = "%identity"

let message = (~loc=?, exn) =>
  exn->Js.Exn.message->Belt.Option.getWithDefault("unspecified error") ++
    loc->Belt.Option.mapWithDefault("", loc => ` at ${loc}`)
