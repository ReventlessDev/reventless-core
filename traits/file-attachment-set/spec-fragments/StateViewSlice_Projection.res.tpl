// Fragment: the read-model contribution. On the view's state, two fields — the
// primary as one string, which is what a card, a gallery tile and a reference
// cell draw, and the whole set:
//
//   @schema type {{entity}}Attachment = { {{file}}: Reventless.UploadableImage.t, altText?: string}
//   …
//   {{file}}?: Reventless.UploadableImage.t,
//   {{file}}s: array<{{entity}}Attachment>,
//
// and these projection arms.

// The fallback to the first attached is the trait's rule, applied here over the
// view's own rows so a card never shows no image while the set holds one.
let withPrimary = (state: {{View}}.state, chosen: option<string>) => {
  ...state,
  {{file}}: ?TraitFileAttachmentSet.FileAttachmentSet_Rules.primaryOf(
    ~chosen,
    ~attached=state.{{file}}s->Array.map(a => a.{{file}}),
  ),
}

  | {{Entity}}ImageAttached({ {{entityId}}, {{file}}, altText: ?altText}) => [
      Update({{entityId}}, state =>
        state.{{file}}s->Array.some(a => a.{{file}} == {{file}})
          ? state
          : withPrimary(
              {...state, {{file}}s: state.{{file}}s->Array.concat([{ {{file}}, altText: ?altText}])},
              state.{{file}},
            )
      ),
    ]
  | {{Entity}}ImageRemoved({ {{entityId}}, {{file}} }) => [
      Update({{entityId}}, state =>
        withPrimary(
          {...state, {{file}}s: state.{{file}}s->Array.filter(a => a.{{file}} != {{file}})},
          state.{{file}} == Some({{file}}) ? None : state.{{file}},
        )
      ),
    ]
  | {{Entity}}PrimaryImageSet({ {{entityId}}, {{file}} }) => [Update({{entityId}}, state => {...state, {{file}} })]
  | {{Entity}}ImageAltTextSet({ {{entityId}}, {{file}}, altText}) => [
      Update({{entityId}}, state => {
        ...state,
        {{file}}s: state.{{file}}s->Array.map(a => a.{{file}} == {{file}} ? {...a, altText} : a),
      }),
    ]
