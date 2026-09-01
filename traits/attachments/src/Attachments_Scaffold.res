/**
The graft's spec surface, written rather than transcribed.

`Attachments_Rules` is the competency, compiled once. What a host still needs is
the *declarations* the rules act on — its own commands, events and errors, in its
own vocabulary, in files it owns. Those cannot come from a functor: a host binds
the source module, so the constructor names are the host's, not the trait's.

They do not have to be typed by hand, though, and that is all this module
changes. It takes the names and hands back real `.res` files. The declarations
are as host-owned as before; only the transcription is gone.

**Why this is code and not a template.** A `.res.tpl` compiles nowhere and is
checked by nothing: it is transcribed from a working host and drifts from it
silently. This module compiles with the trait, its config is sury-validated so a
misspelled key fails at emit rather than at paste-compile, and its output can be
built and run through the trait's own conformance suite — which is what the pack
check does.

**What it does not do.** It never writes the host's policy. Which states an
attachment may be changed in, which refusal comes first, what a host does with
its own events — those differ across every host of this trait (one refuses on a
three-state shelf, another on a single boolean), and expressing them in a config
is how a scaffolder acquires a policy language nobody asked for. They are left
as `TODO(graft)` markers, and the developer writes ReScript, which is better at
this than any config could be.
*/

/**
The names a graft needs, and nothing else.

Everything here is a name or a literal spliced into an annotation. Nothing here
is control flow — that boundary is what keeps this a scaffolder rather than a
worse ReScript.
*/
@schema
type config = {
  /** The host entity, capitalised: `"Product"`. */
  entity: string,
  /** Its id field: `"productId"`. */
  entityId: string,
  /**
  What this host calls one attachment, capitalised and singular: `"Image"`,
  `"Document"`, `"Attachment"`.

  Carried rather than assumed, because it is the host's word and it runs through
  every name the graft declares — `AttachProductImage`, `ProductImageAttached`,
  `ProductPrimaryImageSet`. A trait that hard-wired "Image" would be an image
  trait, and this one holds references, not pictures.
  */
  noun: string,
  /** The attachment field, named for the store it draws from: `"productImage"`. */
  file: string,
  /** The host event that brings the entity into existence: `"ProductAdded"`. */
  created: string,
  /** Whether that event carries the entity id. `false` for a payload-less
      creation like `CategoryAdded`, which both shipped hosts differ on. */
  createdCarriesEntityId?: bool,
  /** The view whose lifecycle states `@transition` names: `"Products"`. */
  view: string,
  /** The semantic type of the reference. `Reventless.UploadableImage.t` unless
      the host attaches something other than pictures. */
  refType?: string,
  /** Spliced verbatim between the parentheses of `@authorize(…)` on every
      command. Omitted ⇒ no annotation, and the host's default applies. */
  authorize?: string,
  /** Spliced verbatim into `@transition([…])`. Omitted ⇒ no annotation, which
      is the honest default: which states an attachment may change in is policy. */
  transition?: array<string>,
  /** Two distinct references for the conformance fixtures. Defaulted when absent
      — they are test data, not a decision. */
  refA?: string,
  refB?: string,
}

/** A file the graft owns outright, written to disk. */
type file = {path: string, contents: string}

/** Arms for a file the host already owns. Printed for a human to place, never
    written: inserting into an existing ordered `switch` is an AST operation, and
    a text splice into the wrong arm is a bug the compiler cannot see. */
type patch = {into: string, at: string, contents: string}

type output = {files: array<file>, patches: array<patch>}

// ── The vocabulary, derived once ─────────────────────────────────────────────
//
// One record so every emitted file spells a name the same way by construction.
// The rules match the two shipped hosts exactly: `ProductImages` /
// `AttachProductImage` / `ProductImageAttached` / `ProductPrimaryImageSet`, and
// the same with `Category`.

type names = {
  slice: string,
  attachCmd: string,
  removeCmd: string,
  setPrimaryCmd: string,
  setAltTextCmd: string,
  attached: string,
  removed: string,
  primarySet: string,
  altTextSet: string,
  notFound: string,
  notAttached: string,
}

let namesOf = (c: config): names => {
  let subject = c.entity ++ c.noun
  {
    slice: subject ++ "s",
    attachCmd: "Attach" ++ subject,
    removeCmd: "Remove" ++ subject,
    setPrimaryCmd: "SetPrimary" ++ subject,
    setAltTextCmd: "Set" ++ subject ++ "AltText",
    attached: subject ++ "Attached",
    removed: subject ++ "Removed",
    primarySet: c.entity ++ "Primary" ++ c.noun ++ "Set",
    altTextSet: subject ++ "AltTextSet",
    notFound: c.entity ++ "NotFound",
    notAttached: subject ++ "NotAttached",
  }
}

let refTypeOf = (c: config) => c.refType->Option.getOr("Reventless.UploadableImage.t")

// `@authorize` and `@transition` are the host's policy, so an absent one emits
// nothing at all rather than a permissive default — a graft that silently
// declared "anyone, in any state" would be worse than one that declares nothing.
let commandAttributes = (c: config): string => {
  let lines =
    [
      c.authorize->Option.map(a => `  | @authorize(${a})`),
      c.transition->Option.map(states => `  @transition([${states->Array.join(", ")}])`),
    ]->Array.filterMap(l => l)
  switch lines {
  | [] => "  | "
  | ls => ls->Array.join("\n") ++ "\n  "
  }
}

let lines = (ls: array<string>) => ls->Array.join("\n")

// ── The slice spec ───────────────────────────────────────────────────────────

let sliceSpec = (c: config): string => {
  let n = namesOf(c)
  let ref = refTypeOf(c)
  let attrs = commandAttributes(c)
  let createdArm =
    c.createdCarriesEntityId->Option.getOr(true)
      ? `  | ${c.created}({ ${c.entityId}: string})`
      : `  | ${c.created}`
  lines([
    `// ${n.slice} StateChangeSlice: ${c.entity}'s attachment set — attach, remove,`,
    `// choose the primary, caption. A graft of the Attachments trait; the set's rules`,
    `// are the trait's and are asserted by its conformance suite, bound in the tests.`,
    `//`,
    `// Emitted by the trait. Everything below is this host's own vocabulary, so it is`,
    `// ordinary source from here on — edit it freely.`,
    ``,
    `@@reventless.spec`,
    ``,
    `@schema`,
    `type consumedEvent =`,
    createdArm,
    `  | ${n.attached}({ ${c.file}: string})`,
    `  | ${n.removed}({ ${c.file}: string})`,
    `  | ${n.primarySet}({ ${c.file}: string})`,
    `  | ${n.altTextSet}({ ${c.file}: string, altText: string})`,
    `  // TODO(graft): add the events this host's own refusal turns on — whatever`,
    `  // moves it into a state where attachments may not be changed.`,
    ``,
    `@schema`,
    `type command =`,
    `${attrs}${n.attachCmd}({ ${c.entityId}: string, ${c.file}: ${ref}, altText?: string})`,
    `${attrs}${n.removeCmd}({ ${c.entityId}: string, ${c.file}: ${ref}})`,
    `${attrs}${n.setPrimaryCmd}({ ${c.entityId}: string, ${c.file}: ${ref}})`,
    `${attrs}${n.setAltTextCmd}({ ${c.entityId}: string, ${c.file}: ${ref}, altText: string})`,
    ``,
    `@schema`,
    `type error =`,
    `  | ${n.notFound}`,
    `  | ${n.notAttached}`,
    `  // TODO(graft): add this host's own refusal.`,
    ``,
    `@schema`,
    `type event =`,
    `  | ${n.attached}({ ${c.entityId}: string, ${c.file}: ${ref}, altText?: string})`,
    `  | ${n.removed}({ ${c.entityId}: string, ${c.file}: ${ref}})`,
    `  | ${n.primarySet}({ ${c.entityId}: string, ${c.file}: ${ref}})`,
    `  | ${n.altTextSet}({ ${c.entityId}: string, ${c.file}: ${ref}, altText: string})`,
    ``,
  ])
}

// ── The slice body ───────────────────────────────────────────────────────────

let sliceBehavior = (c: config): string => {
  let n = namesOf(c)
  lines([
    `@@reventless.behavior`,
    ``,
    `// The set's rules are the trait's. What is left here is this host's own refusal`,
    `// and the mapping between its constructors and the trait's ops and facts.`,
    `module Attachments = TraitAttachments.Attachments_Rules`,
    ``,
    `type state = {exists: bool, attachments: Attachments.t}`,
    ``,
    `let initialState = {exists: false, attachments: Attachments.empty}`,
    ``,
    `let evolve = (state, event) => {`,
    `  let fold = fact => {...state, attachments: state.attachments->Attachments.evolve(fact)}`,
    `  switch event {`,
    `  | ${c.created}(_) => {...state, exists: true}`,
    `  | ${n.attached}({${c.file}}) => fold(Attached({ref: ${c.file}, altText: None}))`,
    `  | ${n.removed}({${c.file}}) => fold(Removed({ref: ${c.file}}))`,
    `  | ${n.primarySet}({${c.file}}) => fold(PrimarySet({ref: ${c.file}}))`,
    `  | ${n.altTextSet}({${c.file}, altText}) => fold(AltTextSet({ref: ${c.file}, altText}))`,
    `  // TODO(graft): fold this host's own events into its own state.`,
    `  }`,
    `}`,
    ``,
    `let toOp = command =>`,
    `  switch command {`,
    `  | ${n.attachCmd}({${c.entityId}, ${c.file}, altText: ?altText}) => (`,
    `      ${c.entityId},`,
    `      Attachments.Attach({ref: ${c.file}, altText}),`,
    `    )`,
    `  | ${n.removeCmd}({${c.entityId}, ${c.file}}) => (`,
    `      ${c.entityId},`,
    `      Attachments.Remove({ref: ${c.file}}),`,
    `    )`,
    `  | ${n.setPrimaryCmd}({${c.entityId}, ${c.file}}) => (`,
    `      ${c.entityId},`,
    `      Attachments.SetPrimary({ref: ${c.file}}),`,
    `    )`,
    `  | ${n.setAltTextCmd}({${c.entityId}, ${c.file}, altText}) => (`,
    `      ${c.entityId},`,
    `      Attachments.SetAltText({ref: ${c.file}, altText}),`,
    `    )`,
    `  }`,
    ``,
    `let toEvent = (${c.entityId}, fact) =>`,
    `  switch fact {`,
    `  | Attachments.Attached({ref, altText}) =>`,
    `    ${n.attached}({${c.entityId}, ${c.file}: ref, altText: ?altText})`,
    `  | Attachments.Removed({ref}) => ${n.removed}({${c.entityId}, ${c.file}: ref})`,
    `  | Attachments.PrimarySet({ref}) => ${n.primarySet}({${c.entityId}, ${c.file}: ref})`,
    `  | Attachments.AltTextSet({ref, altText}) =>`,
    `    ${n.altTextSet}({${c.entityId}, ${c.file}: ref, altText})`,
    `  }`,
    ``,
    `let decide = (state, command) =>`,
    `  if !state.exists {`,
    `    Error(${n.notFound})`,
    `  } else {`,
    `    // TODO(graft): this host's own refusal goes here, ahead of the set's rules —`,
    `    // an \`else if\` returning the error added above. A graft with no extra refusal`,
    `    // is a complete graft, so leaving this is legitimate.`,
    `    let (${c.entityId}, op) = toOp(command)`,
    `    switch state.attachments->Attachments.decide(op) {`,
    `    | Error(#NotAttached) => Error(${n.notAttached})`,
    `    | Ok(None) => Ok([])`,
    `    | Ok(Some(fact)) => Ok([toEvent(${c.entityId}, fact)])`,
    `    }`,
    `  }`,
    ``,
  ])
}

// ── The conformance binding ──────────────────────────────────────────────────
//
// Emitted whole and final. It is pure name-mapping — every line of it is
// already in the config — and it is the file a host would otherwise write twice
// per attachment host, by hand, with nothing checking the names line up.

let conformanceBinding = (c: config): string => {
  let n = namesOf(c)
  let id = "e1"
  let refA = c.refA->Option.getOr(`/uploads/00000000-0000-4000-8000-000000000001/a`)
  let refB = c.refB->Option.getOr(`/uploads/00000000-0000-4000-8000-000000000002/b`)
  let createdValue =
    c.createdCarriesEntityId->Option.getOr(true)
      ? `${c.created}({ ${c.entityId}: "${id}"})`
      : c.created
  lines([
    `// The Attachments trait's conformance suite, bound to \`${n.slice}\`.`,
    `// Emitted whole: every name here is one the graft already declared.`,
    ``,
    `module Binding = {`,
    `  type ref = string`,
    `  let refA = "${refA}"`,
    `  let refB = "${refB}"`,
    ``,
    `  module Spec = ${n.slice}`,
    `  module Behavior = ${n.slice}_Behavior`,
    ``,
    `  // Annotated: the slice consumes and emits same-named constructors.`,
    `  let created: array<${n.slice}.consumedEvent> = [${createdValue}]`,
    `  let attachedC = (ref): ${n.slice}.consumedEvent => ${n.attached}({ ${c.file}: ref})`,
    `  let removedC = (ref): ${n.slice}.consumedEvent => ${n.removed}({ ${c.file}: ref})`,
    `  let primarySetC = (ref): ${n.slice}.consumedEvent => ${n.primarySet}({ ${c.file}: ref})`,
    `  let altTextSetC = (ref, altText): ${n.slice}.consumedEvent =>`,
    `    ${n.altTextSet}({ ${c.file}: ref, altText})`,
    ``,
    `  let attach = ref => ${n.slice}.${n.attachCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let remove = ref => ${n.slice}.${n.removeCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let setPrimary = ref =>`,
    `    ${n.slice}.${n.setPrimaryCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let setAltText = (ref, altText) =>`,
    `    ${n.slice}.${n.setAltTextCmd}({ ${c.entityId}: "${id}", ${c.file}: ref, altText})`,
    ``,
    `  let attached = ref => ${n.slice}.${n.attached}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let removed = ref => ${n.slice}.${n.removed}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let primarySet = ref =>`,
    `    ${n.slice}.${n.primarySet}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let altTextSet = (ref, altText) =>`,
    `    ${n.slice}.${n.altTextSet}({ ${c.entityId}: "${id}", ${c.file}: ref, altText})`,
    `  let notAttached = ${n.slice}.${n.notAttached}`,
    `}`,
    ``,
    `module Conformance = TraitAttachments.Attachments_Conformance.Make(Binding)`,
    ``,
    `Conformance.register()`,
    ``,
  ])
}

// ── The projection patch ─────────────────────────────────────────────────────
//
// Printed, not written: the view already exists and its projection is an ordered
// `switch` the host wrote. Placing an arm in it is the one part of a graft this
// module deliberately does not automate.

let projectionPatch = (c: config): patch => {
  let n = namesOf(c)
  {
    into: `StateViewSliceStream/${c.view}_Projection.res`,
    at: `the projection's \`switch\`, and two fields on \`${c.view}\`'s state`,
    contents: lines([
      `// On the view's state, two fields — the set, and its primary as one string.`,
      `// The second is not redundancy: a card, a gallery tile and a reference cell`,
      `// each read one image-semantic string per row, so without it every tile is blank.`,
      `//`,
      `//   ${c.file}s: array<{${c.file}: string, altText?: string}>,`,
      `//   ${c.file}?: string,`,
      ``,
      `| ${n.attached}({${c.entityId}, ${c.file}, altText: ?altText}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    let ${c.file}s = Array.concat(state.${c.file}s, [{${c.file}: ${c.file}, altText: ?altText}])`,
      `    {...state, ${c.file}s, ${c.file}: ?withPrimary(${c.file}s, state.primaryChosen)}`,
      `  })`,
      `| ${n.removed}({${c.entityId}, ${c.file}}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    let ${c.file}s = state.${c.file}s->Array.filter(m => m.${c.file} != ${c.file})`,
      `    {...state, ${c.file}s, ${c.file}: ?withPrimary(${c.file}s, state.primaryChosen)}`,
      `  })`,
      `| ${n.primarySet}({${c.entityId}, ${c.file}}) =>`,
      `  Update(${c.entityId}, state => {...state, ${c.file}: Some(${c.file})})`,
      `| ${n.altTextSet}({${c.entityId}, ${c.file}, altText}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    ...state,`,
      `    ${c.file}s: state.${c.file}s->Array.map(m =>`,
      `      m.${c.file} == ${c.file} ? {...m, altText} : m`,
      `    ),`,
      `  })`,
      ``,
      `// The primary a reader should show: the one chosen, else the first attached —`,
      `// the same rule the trait applies, over the view's own rows.`,
      `let withPrimary = (members, chosen) =>`,
      `  TraitAttachments.Attachments_Rules.primaryOf(`,
      `    ~chosen,`,
      `    ~attached=members->Array.map(m => m.${c.file}),`,
      `  )`,
    ]),
  }
}

/**
Emit a graft.

Three files written, one patch printed. The files are the host's from the moment
they land — nothing regenerates them, and nothing compares against them later.
*/
let emit = (~config: config, ~into: string, ~tests: string): output => {
  let n = namesOf(config)
  {
    files: [
      {path: `${into}/StateChangeSlice/${n.slice}.res`, contents: sliceSpec(config)},
      {
        path: `${into}/StateChangeSlice/${n.slice}_Behavior.res`,
        contents: sliceBehavior(config),
      },
      {
        path: `${tests}/${n.slice}Conformance_GWT.res`,
        contents: conformanceBinding(config),
      },
    ],
    patches: [projectionPatch(config)],
  }
}
