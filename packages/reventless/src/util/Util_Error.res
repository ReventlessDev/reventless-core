type t = {code: string, message: string}

@deprecated("now supported by standard library")
external ofPromise: Js.Promise.error => t = "%identity"

let message = (~loc=?, exn) =>
  exn->Js.Exn.message->Option.getOr("unspecified error") ++
    loc->Option.mapOr("", loc => ` at ${loc}`)
