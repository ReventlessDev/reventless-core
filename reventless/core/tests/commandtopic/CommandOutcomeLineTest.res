// Each command outcome is written as one info line with the command's ids, which is where a
// deployed platform's tools read what became of a command; a platform that carries outcomes
// another way turns the lines off.

open JestGlobals

type consoleObj = {mutable log: string => unit}
@val external _console: consoleObj = "console"

let captureLogs = (fn: unit => unit): array<JSON.t> => {
  let captured = []
  let original = _console.log
  _console.log = s => captured->Array.push(s)
  let result = try {
    fn()
    Ok()
  } catch {
  | e => Error(e)
  }
  _console.log = original
  switch result {
  | Ok() =>
    captured->Array.filterMap(s =>
      try Some(JSON.parseOrThrow(s)) catch {
      | _ => None
      }
    )
  | Error(e) => throw(e)
  }
}

let field = (j: JSON.t, path: array<string>): option<string> =>
  path
  ->Array.reduce(Some(j), (at, key) =>
    at->Option.flatMap(JSON.Decode.object)->Option.flatMap(d => d->Dict.get(key))
  )
  ->Option.flatMap(v =>
    switch v {
    | JSON.String(s) => Some(s)
    | JSON.Number(n) => Some(n->Float.toString)
    | _ => None
    }
  )

let outcomeLines = lines =>
  lines->Array.filter(l =>
    switch field(l, ["message"]) {
    | Some("command accepted" | "command rejected") => true
    | _ => false
    }
  )

testSync("an accepted command is written with its ids, entity and event count", () => {
  let lines =
    captureLogs(() =>
      CommandTopic_Helpers.fireCommandOutcome(
        ~component="Order",
        ~reference="c-1",
        ~correlationId="c-1",
        OutcomeAccepted({entityId: Some("o-1"), eventCount: 2}),
      )
    )->outcomeLines
  expect(
    lines->Array.map(l => (
      field(l, ["message"]),
      field(l, ["comp"]),
      field(l, ["msgId"]),
      field(l, ["correlationId"]),
      field(l, ["detail", "entityId"]),
      field(l, ["detail", "eventCount"]),
    )),
  )->toEqual([
    (
      Some("command accepted"),
      Some("CommandTopic(Order)"),
      Some("c-1"),
      Some("c-1"),
      Some("o-1"),
      Some("2"),
    ),
  ])
})

testSync("a rejected command is written with its code and cause", () => {
  let lines =
    captureLogs(() =>
      CommandTopic_Helpers.fireCommandOutcome(
        ~component="Order",
        ~reference="c-2",
        ~correlationId="k-1",
        ~causationId="e-1",
        OutcomeRejected({errorCode: "Forbidden", errorDetail: "secret", cause: AccessRefusal}),
      )
    )->outcomeLines
  expect(
    lines->Array.map(l => (
      field(l, ["message"]),
      field(l, ["level"]),
      field(l, ["causationId"]),
      field(l, ["detail", "errorCode"]),
      field(l, ["detail", "cause"]),
      field(l, ["detail", "errorDetail"]),
    )),
  )->toEqual([
    (Some("command rejected"), Some("INFO"), Some("e-1"), Some("Forbidden"), Some("ACCESS"), None),
  ])
})

testSync("a platform that carries outcomes another way writes no line", () => {
  CommandTopic_Helpers.outcomeLines := false
  let lines =
    captureLogs(() =>
      CommandTopic_Helpers.fireCommandOutcome(
        ~component="Order",
        ~reference="c-3",
        OutcomeAccepted({entityId: None, eventCount: 1}),
      )
    )->outcomeLines
  CommandTopic_Helpers.outcomeLines := true
  expect(lines)->toEqual([])
})
