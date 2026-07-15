// Typed bindings for the exception reflection in the companion `ExnReflect.mjs`.
// Inspecting an arbitrary thrown value's shape (`.message`, `RE_EXN_ID`/`_1`,
// `.stack`, a bare string, `throw null`) is untyped work ReScript can't
// pattern-match, so it lives whole in that JS module — no `%raw`, no `Obj.magic`
// here. Used by the runner's catch block to surface a test body's real error
// (e.g. a slice's `failwith("not implemented: …")`) instead of "unknown error".

// A human-readable message from any thrown value.
@module("./ExnReflect.mjs")
external extract: exn => string = "extractMessage"

// The `.stack` of a thrown JS `Error`, or "" when absent.
@module("./ExnReflect.mjs")
external stack: exn => string = "stackOf"
