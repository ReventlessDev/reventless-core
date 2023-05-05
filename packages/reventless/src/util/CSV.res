@ocaml.doc(" FastCSV bindings with added helper functions to handle Validation.t as well ")
include FastCSV

@ocaml.doc(" Add correct callback for validation to Validation.t - to be used in validation function
 *  TODO: hide behind an interface definition
 ")
let fromValidation: (Validation.t<unit, string>, callback) => calledBack = (validation, cb) =>
  switch validation {
  | Failure(msg) => cb->toInvalid(msg)
  | Failures(msgs) => cb->toInvalid(msgs->Js.Array2.joinWith(", "))
  | Success(_)
  | Successes(_) =>
    cb->toValid
  }

@ocaml.doc(" Register a single validation function based on Validation.t
 *  example:
 *  {[
 *    parseFile(~path=\"x\",())
 *    -> validateValidation(_row => Validation.Failure(\"Some reason for invalidation\"))
 *  ]}
 ")
let validateValidation: (row => Validation.t<unit, string>, t) => t = (validation, parser) =>
  parser->validate((row, cb) => row->validation->fromValidation(cb))
