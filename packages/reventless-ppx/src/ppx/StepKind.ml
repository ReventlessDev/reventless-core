(* What one step of a scenario sidecar (`*.gwt.json`) asserts. The sidecar
   writes each kind as its constructor's name, the same name the reader's
   variant (`SidecarStepKind` in reventless-spec) gives the case, so the word is
   the type on both sides. A test in reventless-spec reads [word] below and fails
   when a word written here is not a case there, or a case there is not written
   here: keep one arm per line, `| Name -> "Name"`. *)

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
  (* A step the sidecar could not read; its `of` names the kind it stands for. *)
  | Opaque

let word = function
  | Event -> "Event"
  | Command -> "Command"
  | Input -> "Input"
  | Error -> "Error"
  | SideEffect -> "SideEffect"
  | State -> "State"
  | NoEvent -> "NoEvent"
  | NoState -> "NoState"
  | Forbidden -> "Forbidden"
  | NoCommand -> "NoCommand"
  | Todo -> "Todo"
  | NoTodo -> "NoTodo"
  | Capabilities -> "Capabilities"
  | Sweep -> "Sweep"
  | Process -> "Process"
  | Exhausted -> "Exhausted"
  | Resolved -> "Resolved"
  | NotUnderstood -> "NotUnderstood"
  | InputRefused -> "InputRefused"
  | Sent -> "Sent"
  | NothingSent -> "NothingSent"
  | TodoStatus -> "TodoStatus"
  | Retries -> "Retries"
  | PublicEvent -> "PublicEvent"
  | Opaque -> "Opaque"
