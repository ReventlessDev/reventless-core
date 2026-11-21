// The `Outcome` algebra — Stage 2 of the reventless-gwt plan.
//
// Every `then*` combinator in every GWT DSL returns `Outcome.outcome`
// (`result<unit, mismatch>`). The runner, the human formatter, the AI loop,
// and the IDE all consume the same `Outcome` value, just rendered differently.
//
// See `docs/analysis/given-when-then-specifications.md` §3.2 for the canonical
// shape and §3.3 for the JSON rendering. Stage 7 adds sury-aware rendering and
// structural `fieldDiff`. Stage 4 added `AppendConditionMismatch`.

// The function whose fold produced a state: a decision's `evolve`, or a view's
// `project`. Absent means `Evolve`, so a harness that does not say keeps its hint.
type fold = Evolve | Project

/** The kind of part a flow's step runs. */
type partKind =
  | @as("Decision") Decision
  | @as("Aggregate") Aggregate
  | @as("View") View
  | @as("Automation") Automation
  | @as("Outbound") Outbound
  | @as("Inbound") Inbound
  | @as("ExtensionPoint") ExtensionPoint
  | @as("Extension") Extension
  | @as("Query") Query
  | @as("SideEffect") SideEffect

type part = {kind: partKind, name: string}

/** Where in a flow a mismatch was found: the step's number among all `total`
    steps of the flow, its verb, and the part it ran when it ran one. */
type step = {number: int, total: int, verb: string, part?: part}

type mismatch =
  | EventsMismatch({expected: array<JSON.t>, actual: array<JSON.t>, step?: step})
  | ErrorMismatch({
      expected: JSON.t,
      actual: option<JSON.t>,
      actualEvents: array<JSON.t>,
      step?: step,
    })
  | StateMismatch({
      key: string,
      expected: option<JSON.t>,
      actual: option<JSON.t>,
      fold?: fold,
      step?: step,
    })
  | NoEventExpected({actual: array<JSON.t>, step?: step})
  | TodoMismatch({expected: array<(string, JSON.t)>, actual: array<(string, JSON.t)>, step?: step})
  | AppendConditionMismatch({expected: JSON.t, actual: JSON.t, step?: step})
  | TranslateError({expected: string, actual: option<string>, step?: step})
  | QueryRowsMismatch({expected: array<JSON.t>, actual: array<JSON.t>, step?: step})
  // The set of published actions (events/commands) emitted by an ExtensionPoint
  // mapping or an Extension delegate diverged from the expectation. Supports
  // one-to-many fan-out (one inbound message → N published actions). Used by
  // `Delegate_GWT` and the cross-plugin `Flow_GWT` boundary steps.
  | PublishedActionsMismatch({expected: array<JSON.t>, actual: array<JSON.t>, step?: step})
  // A DCB consistency boundary could not derive its tag scope, so the runtime
  // falls back to `@crossPartition` annotations and loses the cross-partition
  // reference reads named in `dropped`. Not a mismatch between an expectation
  // and a value — every slice in it still behaves correctly in isolation, which
  // is exactly why it needs its own outcome: the defect is in the composition,
  // and nothing that tests one slice can see it.
  | ScopeDegraded({
      boundary: string,
      dropped: array<string>,
      ambiguities: array<string>,
      step?: step,
    })
  // A DCB consistency boundary whose storage partition cannot be derived: a slice
  // with no inferable key, or a `@partitionTag` inference contradicts. Deploy and
  // boot refuse such a boundary, so its flow test fails with the same reasons.
  | PartitionUnresolved({boundary: string, reasons: array<string>, step?: step})
  | Throw({error: string, stack: string, step?: step})

type outcome = result<unit, mismatch>

let pass: outcome = Ok()
let fail = (m): outcome => Error(m)

/** The flow step a mismatch was found at, if a flow found it. */
let stepOf = (m: mismatch): option<step> =>
  switch m {
  | EventsMismatch({?step})
  | ErrorMismatch({?step})
  | StateMismatch({?step})
  | NoEventExpected({?step})
  | TodoMismatch({?step})
  | AppendConditionMismatch({?step})
  | TranslateError({?step})
  | QueryRowsMismatch({?step})
  | PublishedActionsMismatch({?step})
  | ScopeDegraded({?step})
  | PartitionUnresolved({?step})
  | Throw({?step}) => step
  }

/** The mismatch, found at a flow's step. */
let atStep = (m: mismatch, step: step): mismatch =>
  switch m {
  | EventsMismatch(r) => EventsMismatch({...r, step})
  | ErrorMismatch(r) => ErrorMismatch({...r, step})
  | StateMismatch(r) => StateMismatch({...r, step})
  | NoEventExpected(r) => NoEventExpected({...r, step})
  | TodoMismatch(r) => TodoMismatch({...r, step})
  | AppendConditionMismatch(r) => AppendConditionMismatch({...r, step})
  | TranslateError(r) => TranslateError({...r, step})
  | QueryRowsMismatch(r) => QueryRowsMismatch({...r, step})
  | PublishedActionsMismatch(r) => PublishedActionsMismatch({...r, step})
  | ScopeDegraded(r) => ScopeDegraded({...r, step})
  | PartitionUnresolved(r) => PartitionUnresolved({...r, step})
  | Throw(r) => Throw({...r, step})
  }

/** A step as a reader names it: *step 6 of 11, ShipOrder.thenEvent*. */
let describeStep = ({number, total, verb, ?part}: step) => {
  let at = switch part {
  | Some({name}) => `${name}.${verb}`
  | None => verb
  }
  `step ${number->Int.toString} of ${total->Int.toString}, ${at}`
}

/** A mismatch's kind without its values. Its text is the mismatch's constructor name. */
type mismatchKind =
  | @as("EventsMismatch") EventsMismatchKind
  | @as("ErrorMismatch") ErrorMismatchKind
  | @as("StateMismatch") StateMismatchKind
  | @as("NoEventExpected") NoEventExpectedKind
  | @as("TodoMismatch") TodoMismatchKind
  | @as("AppendConditionMismatch") AppendConditionMismatchKind
  | @as("TranslateError") TranslateErrorKind
  | @as("QueryRowsMismatch") QueryRowsMismatchKind
  | @as("PublishedActionsMismatch") PublishedActionsMismatchKind
  | @as("ScopeDegraded") ScopeDegradedKind
  | @as("PartitionUnresolved") PartitionUnresolvedKind
  | @as("Throw") ThrowKind

let kindOf = (m: mismatch): mismatchKind =>
  switch m {
  | EventsMismatch(_) => EventsMismatchKind
  | ErrorMismatch(_) => ErrorMismatchKind
  | StateMismatch(_) => StateMismatchKind
  | NoEventExpected(_) => NoEventExpectedKind
  | TodoMismatch(_) => TodoMismatchKind
  | AppendConditionMismatch(_) => AppendConditionMismatchKind
  | TranslateError(_) => TranslateErrorKind
  | QueryRowsMismatch(_) => QueryRowsMismatchKind
  | PublishedActionsMismatch(_) => PublishedActionsMismatchKind
  | ScopeDegraded(_) => ScopeDegradedKind
  | PartitionUnresolved(_) => PartitionUnresolvedKind
  | Throw(_) => ThrowKind
  }

let kindName = (m: mismatch): string => (kindOf(m) :> string)

let stringifyJson = (j: JSON.t) => JSON.stringify(j, ~space=2)
let stringifyOptJson = (j: option<JSON.t>) =>
  switch j {
  | Some(v) => stringifyJson(v)
  | None => "(none)"
  }
let stringifyJsonArray = (arr: array<JSON.t>) =>
  "[" ++ arr->Array.map(stringifyJson)->Array.join(", ") ++ "]"

let format = (m: mismatch) =>
  switch m {
  | EventsMismatch({expected, actual}) =>
    `EventsMismatch:\n  expected: ${stringifyJsonArray(expected)}\n  actual:   ${stringifyJsonArray(
        actual,
      )}`
  | ErrorMismatch({expected, actual, actualEvents}) =>
    `ErrorMismatch:\n  expected error: ${stringifyJson(
        expected,
      )}\n  actual error:   ${stringifyOptJson(actual)}\n  actual events:  ${stringifyJsonArray(
        actualEvents,
      )}`
  | StateMismatch({key, expected, actual}) =>
    `StateMismatch (key: ${key}):\n  expected: ${stringifyOptJson(
        expected,
      )}\n  actual:   ${stringifyOptJson(actual)}`
  | NoEventExpected({actual}) =>
    `NoEventExpected: expected no events, got:\n  ${stringifyJsonArray(actual)}`
  | TodoMismatch({expected, actual}) => {
      let fmt = arr =>
        arr
        ->Array.map(((id, j)) => `(${id}, ${stringifyJson(j)})`)
        ->Array.join(", ")
      `TodoMismatch:\n  expected: [${fmt(expected)}]\n  actual:   [${fmt(actual)}]`
    }
  | AppendConditionMismatch({expected, actual}) =>
    `AppendConditionMismatch:\n  expected: ${stringifyJson(expected)}\n  actual:   ${stringifyJson(
        actual,
      )}`
  | TranslateError({expected, actual}) =>
    `TranslateError:\n  expected: ${expected}\n  actual:   ${actual->Option.getOr("(none)")}`
  | QueryRowsMismatch({expected, actual}) =>
    `QueryRowsMismatch:\n  expected: ${stringifyJsonArray(
        expected,
      )}\n  actual:   ${stringifyJsonArray(actual)}`
  | PublishedActionsMismatch({expected, actual}) =>
    `PublishedActionsMismatch:\n  expected: ${stringifyJsonArray(
        expected,
      )}\n  actual:   ${stringifyJsonArray(actual)}`
  | ScopeDegraded({boundary, dropped, ambiguities}) =>
    `ScopeDegraded:\n  boundary: ${boundary}\n  dropped:  ${dropped->Array.join(
        ", ",
      )}\n  cause:    ${ambiguities->Array.join(" | ")}`
  | PartitionUnresolved({boundary, reasons}) =>
    `PartitionUnresolved:\n  boundary: ${boundary}\n  cause:    ${reasons->Array.join(" | ")}`
  | Throw({error, stack}) => `Throw: ${error}\n${stack}`
  }
