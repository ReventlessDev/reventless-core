/** this module binds the Error object in global JS namespace */
@deprecated("Use Js.Exn.t instead")
type t

/** constructor of Error => `new Error(string) */
@deprecated("Create separate binding locally when needed.")
@new
external make: string => Js.Exn.t = "Error"

/** convert Js.Exn.t to JsError.t */
@deprecated("Create separate binding locally when needed.")
external ofJsExn: Js.Exn.t => Js.Exn.t = "%identity"

/** convert JsError.t to Js.Exn.t */
@deprecated("Create separate binding locally when needed.")
external toJsExn: Js.Exn.t => Js.Exn.t = "%identity"

/** get the error's message => `(new Error(string)).getMessage() */
@deprecated("Use Js.Exn.message instead")
@get
external getMessage: Js.Exn.t => string = "message"
