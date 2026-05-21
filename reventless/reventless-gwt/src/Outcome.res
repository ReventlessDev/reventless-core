// The `Outcome` algebra — Stage 2 of the reventless-gwt plan.
//
// Every `then*` combinator in every GWT DSL returns `Outcome.outcome`
// (`result<unit, mismatch>`). The runner, the human formatter, the AI loop,
// and the IDE all consume the same `Outcome` value, just rendered differently.
//
// See `docs/analysis/given-when-then-specifications.md` §3.2 for the canonical
// shape and §3.3 for the JSON rendering. Stage 7 adds sury-aware rendering and
// structural `fieldDiff`. Stage 4 added `AppendConditionMismatch`.

type mismatch =
  | EventsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  | ErrorMismatch({
      expected: JSON.t,
      actual: option<JSON.t>,
      actualEvents: array<JSON.t>,
    })
  | StateMismatch({key: string, expected: option<JSON.t>, actual: option<JSON.t>})
  | NoEventExpected({actual: array<JSON.t>})
  | TodoMismatch({expected: array<(string, JSON.t)>, actual: array<(string, JSON.t)>})
  | AppendConditionMismatch({expected: JSON.t, actual: JSON.t})
  | TranslateError({expected: string, actual: option<string>})
  | QueryRowsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  // The set of published actions (events/commands) emitted by an ExtensionPoint
  // mapping or an Extension delegate diverged from the expectation. Supports
  // one-to-many fan-out (one inbound message → N published actions). Used by
  // `Delegate_GWT` and the cross-plugin `Flow_GWT` boundary steps.
  | PublishedActionsMismatch({expected: array<JSON.t>, actual: array<JSON.t>})
  | Throw({error: string, stack: string})

type outcome = result<unit, mismatch>

let pass: outcome = Ok()
let fail = (m): outcome => Error(m)

let kindName = (m: mismatch) =>
  switch m {
  | EventsMismatch(_) => "EventsMismatch"
  | ErrorMismatch(_) => "ErrorMismatch"
  | StateMismatch(_) => "StateMismatch"
  | NoEventExpected(_) => "NoEventExpected"
  | TodoMismatch(_) => "TodoMismatch"
  | AppendConditionMismatch(_) => "AppendConditionMismatch"
  | TranslateError(_) => "TranslateError"
  | QueryRowsMismatch(_) => "QueryRowsMismatch"
  | PublishedActionsMismatch(_) => "PublishedActionsMismatch"
  | Throw(_) => "Throw"
  }

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
    `ErrorMismatch:\n  expected error: ${stringifyJson(expected)}\n  actual error:   ${stringifyOptJson(
        actual,
      )}\n  actual events:  ${stringifyJsonArray(actualEvents)}`
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
    `QueryRowsMismatch:\n  expected: ${stringifyJsonArray(expected)}\n  actual:   ${stringifyJsonArray(
        actual,
      )}`
  | PublishedActionsMismatch({expected, actual}) =>
    `PublishedActionsMismatch:\n  expected: ${stringifyJsonArray(expected)}\n  actual:   ${stringifyJsonArray(
        actual,
      )}`
  | Throw({error, stack}) => `Throw: ${error}\n${stack}`
  }

// Structured JSON payload per §3.3 of the analysis.
// Closed schema — consumers switch on the `kind` discriminator.
// Stage 7 enriches with `rendered` strings and `fieldDiff`.
let toJson = (m: mismatch): JSON.t => {
  let obj = Dict.make()
  obj->Dict.set("kind", JSON.Encode.string(kindName(m)))
  let jsonArr = arr => JSON.Encode.array(arr)
  let optJson = o => o->Option.getOr(JSON.Encode.null)
  switch m {
  | EventsMismatch({expected, actual}) => {
      obj->Dict.set("expected", jsonArr(expected))
      obj->Dict.set("actual", jsonArr(actual))
    }
  | ErrorMismatch({expected, actual, actualEvents}) => {
      obj->Dict.set("expected", expected)
      obj->Dict.set("actual", optJson(actual))
      obj->Dict.set("actualEvents", jsonArr(actualEvents))
    }
  | StateMismatch({key, expected, actual}) => {
      obj->Dict.set("key", JSON.Encode.string(key))
      obj->Dict.set("expected", optJson(expected))
      obj->Dict.set("actual", optJson(actual))
    }
  | NoEventExpected({actual}) => obj->Dict.set("actual", jsonArr(actual))
  | TodoMismatch({expected, actual}) => {
      let pairArr = pairs =>
        pairs
        ->Array.map(((id, v)) => {
          let d = Dict.make()
          d->Dict.set("id", JSON.Encode.string(id))
          d->Dict.set("value", v)
          JSON.Encode.object(d)
        })
        ->jsonArr
      obj->Dict.set("expected", pairArr(expected))
      obj->Dict.set("actual", pairArr(actual))
    }
  | AppendConditionMismatch({expected, actual}) => {
      obj->Dict.set("expected", expected)
      obj->Dict.set("actual", actual)
    }
  | TranslateError({expected, actual}) => {
      obj->Dict.set("expected", JSON.Encode.string(expected))
      obj->Dict.set(
        "actual",
        actual->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
      )
    }
  | QueryRowsMismatch({expected, actual}) => {
      obj->Dict.set("expected", jsonArr(expected))
      obj->Dict.set("actual", jsonArr(actual))
    }
  | PublishedActionsMismatch({expected, actual}) => {
      obj->Dict.set("expected", jsonArr(expected))
      obj->Dict.set("actual", jsonArr(actual))
    }
  | Throw({error, stack}) => {
      obj->Dict.set("error", JSON.Encode.string(error))
      obj->Dict.set("stack", JSON.Encode.string(stack))
    }
  }
  JSON.Encode.object(obj)
}
