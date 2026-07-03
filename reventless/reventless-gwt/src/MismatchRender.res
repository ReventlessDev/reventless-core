// Single source for rendering an `Outcome.mismatch`'s expected/actual/extras
// into RenderRescript strings. The Human and TAP formatters previously each held
// a full 10-arm switch over the mismatch that computed *identical* rendered
// values (`RenderRescript.render*`, the `Error()`/`Ok()` wrapping, the Todo
// `(id, value)` pairs) and differed only in framing — aligned `label: value`
// lines vs YAML `key: "escaped"` lines. This normalizes the value-rendering once;
// each formatter interprets the `field` list with its own framing.
//
// NOT used by JUnit (renders via the older JSON-based `Outcome.format`) nor
// FormatterJson/VsCode (they consume the raw JSON values to build a structured
// `{type, payload, rendered}` + `fieldDiff` payload).

// One rendered piece of a mismatch. The constructor carries the *already
// rendered* string (unescaped — Human uses it raw, TAP yaml-escapes it), except
// the structural markers `ExpectedNoEvents` (Human prints a literal line; TAP
// omits it) and `Stack` (Human appends it raw; TAP labels it as a yaml field).
type field =
  | Expected(string)
  | Actual(string)
  | Key(string)
  | ExpectedNoEvents
  | Error(string)
  | Stack(string)

type normalized = {
  kind: string,
  fields: array<field>,
}

let render = RenderRescript.render
let renderMany = RenderRescript.renderMany
let renderOption = RenderRescript.renderOption

let normalize = (m: Outcome.mismatch): normalized => {
  let fields = switch m {
  | EventsMismatch({expected, actual}) => [Expected(renderMany(expected)), Actual(renderMany(actual))]
  | ErrorMismatch({expected, actual, actualEvents}) => [
      Expected(`Error(${render(expected)})`),
      Actual(
        switch actual {
        | Some(v) => `Error(${render(v)})`
        | None => `Ok(${renderMany(actualEvents)})`
        },
      ),
    ]
  | StateMismatch({key, expected, actual}) => [
      Key(key),
      Expected(renderOption(expected)),
      Actual(renderOption(actual)),
    ]
  | NoEventExpected({actual}) => [ExpectedNoEvents, Actual(renderMany(actual))]
  | TodoMismatch({expected, actual}) =>
    let fmt = (arr: array<(string, JSON.t)>) =>
      "[" ++ arr->Array.map(((id, v)) => `(${id}, ${render(v)})`)->Array.join(", ") ++ "]"
    [Expected(fmt(expected)), Actual(fmt(actual))]
  | AppendConditionMismatch({expected, actual}) => [
      Expected(render(expected)),
      Actual(render(actual)),
    ]
  | TranslateError({expected, actual}) => [
      Expected(expected),
      Actual(actual->Option.getOr("(none)")),
    ]
  | QueryRowsMismatch({expected, actual}) => [Expected(renderMany(expected)), Actual(renderMany(actual))]
  | PublishedActionsMismatch({expected, actual}) => [
      Expected(renderMany(expected)),
      Actual(renderMany(actual)),
    ]
  | Throw({error, stack}) => [Error(error), Stack(stack)]
  }
  {kind: Outcome.kindName(m), fields}
}
