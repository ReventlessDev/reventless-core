// Scaffold: the read-model contribution. On the view's state, two fields — the
// primary as one string, which is what a card, a gallery tile and a reference
// cell draw, and the whole set:
//
//   @schema type {{entity}}Attachment = { {{file}}: Reventless.UploadableImage.t, altText?: string}
//   …
//   {{file}}?: Reventless.UploadableImage.t,
//   {{file}}s: array<{{entity}}Attachment>,
//
// and these projection arms. The primary falls back to the first attached, so a
// set never shows no image while it has one.

let withPrimary = (state: {{View}}.state, chosen: option<string>) =>
  switch chosen {
  | Some(_) as p => {...state, {{file}}: ?p}
  | None =>
    switch state.{{file}}s->Array.get(0) {
    | Some(first) => {...state, {{file}}: first.{{file}} }
    | None => {...state, {{file}}: ?None}
    }
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
