type t = {code: string, message: string}

@deprecated("now supported by standard library")
external ofPromise: exn => t = "%identity"

let message = (~loc=?, exn) =>
  exn->JsExn.message->Option.getOr("unspecified error") ++
    loc->Option.mapOr("", loc => ` at ${loc}`)

/** Safely extracts a message string from any caught JS exception-like value. */
let messageFromUnknown: (unknown, string) => string = %raw(`
  function(err, fallback) {
    if (err != null && typeof err.message === 'string') return err.message;
    return fallback;
  }
`)
