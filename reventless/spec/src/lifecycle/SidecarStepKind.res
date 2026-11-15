/***
What one step of a scenario sidecar (`*.gwt.json`) asserts, by the `kind` word the
sidecar carries: the PPX writes it from a step's verb, and a recorded run writes the
same words. Each word is its case's name. Read once where the sidecar is read; every
reader after that switches on the variant.

A sidecar is written by a build that may be newer or older than its reader, so a
word this build does not know reads as `OtherSidecarStep`, keeping the word.
*/

@unboxed
type t =
  | Event
  | Command
  | Input
  | Error
  | SideEffect
  | State
  | NoEvent
  | NoState
  | Forbidden
  | NoCommand
  | Todo
  | NoTodo
  | Capabilities
  | Sweep
  | Process
  | Exhausted
  | Resolved
  | NotUnderstood
  | InputRefused
  | Sent
  | NothingSent
  | TodoStatus
  | Retries
  | PublicEvent
  /** A step the sidecar could not read; its `of` names the kind it stands for. */
  | Opaque
  | OtherSidecarStep(string)

/** Every kind this build knows, in the order the PPX lists them. */
let known = [
  Event,
  Command,
  Input,
  Error,
  SideEffect,
  State,
  NoEvent,
  NoState,
  Forbidden,
  NoCommand,
  Todo,
  NoTodo,
  Capabilities,
  Sweep,
  Process,
  Exhausted,
  Resolved,
  NotUnderstood,
  InputRefused,
  Sent,
  NothingSent,
  TodoStatus,
  Retries,
  PublicEvent,
  Opaque,
]

/** The kind a word names. Every word is one: a word this build does not know is
    `OtherSidecarStep` of it. */
external ofString: string => t = "%identity"

/** The kind's word, as the sidecar spells it. */
let toString = (kind: t): string => (kind :> string)

/** Why a sidecar holds a word this build does not know, for the person who has to
    act on it. Every word is a case's name, so it starts upper case; an older
    reventless-ppx wrote lower-case words (`event`, `noEvent`). */
let unknownWordReason = (word: string): string =>
  /^[a-z]/->RegExp.test(word)
    ? `the sidecar was written by an older reventless-ppx, which spelled the step kind "${word}" in ` ++
      `lower case. Update @reventlessdev/reventless-ppx to the release that matches ` ++ `@reventlessdev/reventless-spec, then build again.`
    : `the sidecar names a step kind "${word}" this reventless-spec does not know, so it was written by ` ++
      `a newer reventless-ppx. Update @reventlessdev/reventless-spec to the release that matches ` ++ `@reventlessdev/reventless-ppx.`
