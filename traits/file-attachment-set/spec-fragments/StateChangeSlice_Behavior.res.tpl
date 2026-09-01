// Fragment: the slice body. Paste as `StateChangeSlice/{{Entity}}Images_Behavior.res`.
// The set's rules live in `FileAttachmentSet_Rules` — what is written here is the host's
// own refusal and the mapping between its constructors and the trait's ops and facts.

@@reventless.behavior

module Attachments = TraitFileAttachmentSet.FileAttachmentSet_Rules

// The set is embedded directly: a StateChangeSlice's state is refolded per decision
// and never stored, so a trait release that reshapes it costs no migration.
type state = {exists: bool, images: Attachments.t}

let initialState = {exists: false, images: Attachments.empty}

let evolve = (state, event) => {
  let fold = fact => {...state, images: state.images->Attachments.evolve(fact)}
  switch event {
  | {{Created}}(_) => {...state, exists: true}
  | {{Entity}}ImageAttached({ {{file}} }) => fold(Attached({ref: {{file}}, altText: None}))
  | {{Entity}}ImageRemoved({ {{file}} }) => fold(Removed({ref: {{file}} }))
  | {{Entity}}PrimaryImageSet({ {{file}} }) => fold(PrimarySet({ref: {{file}} }))
  | {{Entity}}ImageAltTextSet({ {{file}}, altText}) => fold(AltTextSet({ref: {{file}}, altText}))
  // Plus the arms the host's own refusal turns on (archived, discontinued …).
  }
}

let toOp = command =>
  switch command {
  | Attach{{Entity}}Image({ {{entityId}}, {{file}}, altText: ?altText}) => (
      {{entityId}},
      Attachments.Attach({ref: {{file}}, altText}),
    )
  | Remove{{Entity}}Image({ {{entityId}}, {{file}} }) => (
      {{entityId}},
      Attachments.Remove({ref: {{file}} }),
    )
  | SetPrimary{{Entity}}Image({ {{entityId}}, {{file}} }) => (
      {{entityId}},
      Attachments.SetPrimary({ref: {{file}} }),
    )
  | Set{{Entity}}ImageAltText({ {{entityId}}, {{file}}, altText}) => (
      {{entityId}},
      Attachments.SetAltText({ref: {{file}}, altText}),
    )
  }

let toEvent = ({{entityId}}, fact) =>
  switch fact {
  | Attachments.Attached({ref, altText}) =>
    {{Entity}}ImageAttached({ {{entityId}}, {{file}}: ref, altText: ?altText})
  | Attachments.Removed({ref}) => {{Entity}}ImageRemoved({ {{entityId}}, {{file}}: ref})
  | Attachments.PrimarySet({ref}) => {{Entity}}PrimaryImageSet({ {{entityId}}, {{file}}: ref})
  | Attachments.AltTextSet({ref, altText}) =>
    {{Entity}}ImageAltTextSet({ {{entityId}}, {{file}}: ref, altText})
  }

let decide = (state, command) =>
  if !state.exists {
    Error({{Entity}}NotFound)
  } else {
    // The host's own refusal (archived, discontinued …) goes here.
    let ({{entityId}}, op) = toOp(command)
    switch state.images->Attachments.decide(op) {
    | Error(#NotAttached) => Error({{Entity}}ImageNotAttached)
    | Ok(None) => Ok([])
    | Ok(Some(fact)) => Ok([toEvent({{entityId}}, fact)])
    }
  }
