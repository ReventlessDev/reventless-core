type t = {code: string, message: string}

@deprecated("now supported by standard library")
external ofPromise: exn => t = "%identity"

let message = (~loc=?, exn) =>
  exn->JsExn.message->Option.getOr("unspecified error") ++
    loc->Option.mapOr("", loc => ` at ${loc}`)
