type t = {code: string, message: string}

external ofPromise: Js.Promise.error => t = "%identity"
