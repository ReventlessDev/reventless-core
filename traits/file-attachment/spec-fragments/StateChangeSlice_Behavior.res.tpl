// Scaffold: the slice body. Paste as `StateChangeSlice/{{Entity}}Images_Behavior.res`.

@@reventless.behavior

// The set in attachment order. `primary` is only the one chosen explicitly: until
// then the first attached is primary, and the projection applies the same rule.
type state = {
  exists: bool,
  attached: array<string>,
  primary: option<string>,
  altTexts: array<(string, string)>,
}

let initialState = {exists: false, attached: [], primary: None, altTexts: []}

let evolve = (state, event) =>
  switch event {
  | {{Created}}(_) => {...state, exists: true}
  | {{Entity}}ImageAttached({ {{file}} }) =>
    state.attached->Array.includes({{file}})
      ? state
      : {...state, attached: state.attached->Array.concat([{{file}}])}
  | {{Entity}}ImageRemoved({ {{file}} }) => {
      ...state,
      attached: state.attached->Array.filter(r => r != {{file}}),
      primary: state.primary == Some({{file}}) ? None : state.primary,
      altTexts: state.altTexts->Array.filter(((r, _)) => r != {{file}}),
    }
  | {{Entity}}PrimaryImageSet({ {{file}} }) => {...state, primary: Some({{file}})}
  | {{Entity}}ImageAltTextSet({ {{file}}, altText}) => {
      ...state,
      altTexts: state.altTexts->Array.filter(((r, _)) => r != {{file}})->Array.concat([({{file}}, altText)]),
    }
  }

let effectivePrimary = state =>
  switch state.primary {
  | Some(_) as p => p
  | None => state.attached->Array.get(0)
  }

let altTextOf = (state, ref) =>
  state.altTexts->Array.find(((r, _)) => r == ref)->Option.map(((_, t)) => t)

let decide = (state, command) =>
  if !state.exists {
    Error({{Entity}}NotFound)
  } else {
    // The host's own refusal (archived, discontinued …) goes here.
    switch command {
    | Attach{{Entity}}Image({ {{entityId}}, {{file}}, altText: ?altText}) =>
      state.attached->Array.includes({{file}})
        ? Ok([])
        : Ok([{{Entity}}ImageAttached({ {{entityId}}, {{file}}, altText: ?altText})])
    | Remove{{Entity}}Image({ {{entityId}}, {{file}} }) =>
      state.attached->Array.includes({{file}})
        ? Ok([{{Entity}}ImageRemoved({ {{entityId}}, {{file}} })])
        : Ok([])
    | SetPrimary{{Entity}}Image({ {{entityId}}, {{file}} }) =>
      if !(state.attached->Array.includes({{file}})) {
        Error({{Entity}}ImageNotAttached)
      } else if effectivePrimary(state) == Some({{file}}) {
        Ok([])
      } else {
        Ok([{{Entity}}PrimaryImageSet({ {{entityId}}, {{file}} })])
      }
    | Set{{Entity}}ImageAltText({ {{entityId}}, {{file}}, altText}) =>
      if !(state.attached->Array.includes({{file}})) {
        Error({{Entity}}ImageNotAttached)
      } else if altTextOf(state, {{file}}) == Some(altText) {
        Ok([])
      } else {
        Ok([{{Entity}}ImageAltTextSet({ {{entityId}}, {{file}}, altText})])
      }
    }
  }
