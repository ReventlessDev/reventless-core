// Classifying an AWS SDK failure, for callers that must tell one apart from the
// rest rather than treat every throw alike.
//
// 🚨 **The error's `name` carries the code; its `message` does not have to.** A
// v3 SDK `DescribeTable` on a missing table throws `name:
// "ResourceNotFoundException"` with the message "Requested resource not found:
// Table: X not found" — which does not contain the code anywhere. A guard written
// against the message alone therefore never matches, and the ordinary case it was
// meant to absorb escapes as an unhandled rejection instead.
//
// That is not hypothetical: it is why this module exists rather than the check
// living inline. A predicate inside a script that runs on import cannot be tested,
// so the version that could never match shipped.
//
// `Auth_ActiveRolePoolAttachment` keeps its own inline copy on purpose — Pulumi
// serialises a dynamic provider's whole closure into stack state, and a helper
// reached through a module import is a dependency that serialisation cannot carry.

@get @return(nullable) external name: JsExn.t => option<string> = "name"

/** Whether a failure carries this AWS error code, by `name` first and message as
  a fallback for wrapped or re-thrown shapes. */
let hasCode = (exn: exn, ~code: string): bool =>
  switch exn->JsExn.fromException {
  | Some(jsErr) =>
    switch (jsErr->name, JsExn.message(jsErr)) {
    | (Some(actual), _) if actual == code => true
    | (_, Some(message)) => message->String.includes(code)
    | _ => false
    }
  | None => false
  }

/** The resource named by the call does not exist — the shape both DynamoDB and
  Cognito use, and normally an absence to handle rather than a failure to report. */
let isNotFound = (exn: exn): bool => exn->hasCode(~code="ResourceNotFoundException")

/**
An escaped exception as one line an operator can act on.

For the top of a CLI: without it Node reports `UnhandledPromiseRejection ...
"#<Object>"`, which names neither the call that failed nor why. Every branch
returns something, because a describer that itself throws replaces one unreadable
failure with another.
*/
let describe = (exn: exn): string =>
  switch exn->JsExn.fromException {
  | Some(jsErr) =>
    switch (jsErr->name, JsExn.message(jsErr)) {
    | (Some(n), Some(m)) => `${n}: ${m}`
    | (Some(n), None) => n
    | (None, Some(m)) => m
    | (None, None) => "an AWS call failed with no message"
    }
  | None => "an unexpected error escaped"
  }
