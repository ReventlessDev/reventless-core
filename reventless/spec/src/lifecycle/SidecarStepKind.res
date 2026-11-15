/***
What one step of a scenario sidecar (`*.gwt.json`) asserts, by the `kind` word the
sidecar carries: the PPX writes it from a step's verb, and a recorded run writes the
same words. Read once where the sidecar is read; every reader after that switches on
the variant.

A sidecar is written by a build that may be newer or older than its reader, so a
word this build does not know reads as `OtherSidecarStep`, keeping the word.
*/

@unboxed
type t =
  | @as("event") Event
  | @as("command") Command
  | @as("input") Input
  | @as("error") Error
  | @as("sideEffect") SideEffect
  | @as("state") State
  | @as("noEvent") NoEvent
  | @as("noState") NoState
  | @as("forbidden") Forbidden
  | @as("noCommand") NoCommand
  | @as("todo") Todo
  | @as("noTodo") NoTodo
  | @as("capabilities") Capabilities
  | @as("sweep") Sweep
  | @as("process") Process
  | @as("exhausted") Exhausted
  | @as("resolved") Resolved
  | @as("notUnderstood") NotUnderstood
  | @as("inputRefused") InputRefused
  | @as("sent") Sent
  | @as("nothingSent") NothingSent
  | @as("todoStatus") TodoStatus
  | @as("retries") Retries
  | @as("publicEvent") PublicEvent
  /** A step the sidecar could not read; its `of` names the kind it stands for. */
  | @as("opaque") Opaque
  | OtherSidecarStep(string)

/** The kind a word names. Every word is one: a word this build does not know is
    `OtherSidecarStep` of it. */
external ofString: string => t = "%identity"

/** The kind's word, as the sidecar spells it. */
let toString = (kind: t): string => (kind :> string)
