// Scaffold: the slice spec. Paste as `StateChangeSlice/{{Entity}}Images.res`.
// `{{file}}` is the attachment field — `productImage`, named for its store, so the
// same `{{file}}s` store is provisioned for every member.

@@reventless.spec

@schema
type consumedEvent =
  | {{Created}}({ {{entityId}}: string})
  | {{Entity}}ImageAttached({ {{file}}: string})
  | {{Entity}}ImageRemoved({ {{file}}: string})
  | {{Entity}}PrimaryImageSet({ {{file}}: string})
  | {{Entity}}ImageAltTextSet({ {{file}}: string, altText: string})
  // Plus whatever the host's own refusal turns on (archived, discontinued …).

@schema
type command =
  | @transition([{{View}}.Listed])
  Attach{{Entity}}Image({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t, altText?: string})
  | @transition([{{View}}.Listed])
  Remove{{Entity}}Image({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t})
  | @transition([{{View}}.Listed])
  SetPrimary{{Entity}}Image({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t})
  | @transition([{{View}}.Listed])
  Set{{Entity}}ImageAltText({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t, altText: string})

@schema
type error =
  | {{Entity}}NotFound
  | {{Entity}}ImageNotAttached

@schema
type event =
  | {{Entity}}ImageAttached({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t, altText?: string})
  | {{Entity}}ImageRemoved({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t})
  | {{Entity}}PrimaryImageSet({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t})
  | {{Entity}}ImageAltTextSet({ {{entityId}}: string, {{file}}: Reventless.UploadableImage.t, altText: string})
