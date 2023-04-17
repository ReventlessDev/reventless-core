@ocaml.doc(" this module binds the Error object in global JS namespace ")
@deprecated("Use Js.Exn.t instead")
type t

@ocaml.doc(" constructor of Error => `new Error(string)` *")
@deprecated("Create separate binding locally when needed.")
@new
external make: string => t = "Error"

@ocaml.doc(" convert Js.Exn.t to JsError.t *")
@deprecated("Create separate binding locally when needed.")
external ofJsExn: Js.Exn.t => t = "%identity"

@ocaml.doc(" convert JsError.t to Js.Exn.t *")
@deprecated("Create separate binding locally when needed.")
external toJsExn: t => Js.Exn.t = "%identity"

@ocaml.doc(" get the error's message => `(new Error(string)).getMessage()` ")
@deprecated("Use Js.Exn.message instead")
@get
external getMessage: t => string = "message"
