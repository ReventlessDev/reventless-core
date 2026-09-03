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
  /**
  How many attachments this host's entity may hold. Absent ⇒ `Many`, so a graft
  written before this key existed emits exactly what it emitted before.

  It is not one rule among the emitted text: it changes which commands exist.
  `Single` emits `Set{Entity}{Noun}` (which replaces), a `Remove{Entity}{Noun}`
  that names no reference — there is only one, and asking a caller to name it is
  asking them to repeat what the row already says — and no primary command at
  all, because a set of one has nothing to choose between. The view field
  changes with them: one captioned image, not an array of them.
  */
  cardinality?: Attachments_Rules.cardinality,
  /** The host event that brings the entity into existence: `"ProductAdded"`. */
  created: string,
  /** Whether that event carries the entity id. `false` for a payload-less
      creation like `CategoryAdded`, which both shipped hosts differ on. */
  createdCarriesEntityId?: bool,
  /** The view whose lifecycle states `transition` names: `"Products"`. */
  view: string,
  /**
  The name of that view's lifecycle enum *type*: `"shelfStatus"`. Only read when
  `transition` is given, because only then is a `lifecycleState` binding emitted.

  Carried rather than derived: the enum is a type on the host's view and nothing
  in the other names reaches it — `Products` has a `shelfStatus`, but a host may
  call its own `state`, `stage` or `phase`. Absent leaves a `TODO(graft)` marker
  in its place, which does not compile; that is deliberate, and better than a
  guess that compiles against the wrong type.
  */
  lifecycleType?: string,
  /** The semantic type of the reference. `Reventless.UploadableImage.t` unless
      the host attaches something other than pictures. */
  refType?: string,
  /** Spliced verbatim between the parentheses of `@authorize(…)` on every
      command. Omitted ⇒ no annotation, and the host's default applies. */
  authorize?: string,
  /** The states the four commands are legal in, as the linked view's own
      constructors: `["Products.Listed", "Products.Archived"]`. Emitted into a
      `commandTransition` switch, not an annotation, so the compiler resolves
      them and a typo here is a build error rather than a dead menu entry.
      Omitted ⇒ a `TODO(graft)` marker, which is the honest default: which
      states an attachment may change in is this host's policy. */
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

let cardinalityOf = (c: config): Attachments_Rules.cardinality =>
  c.cardinality->Option.getOr(Many)

let isSingle = (c: config): bool => cardinalityOf(c) == Single

let namesOf = (c: config): names => {
  let subject = c.entity ++ c.noun
  {
    slice: subject ++ "s",
    // `Set` rather than `Attach` for a bounded set: the command replaces what is
    // there, and `Attach` would name the wrong half of what it does. The *event*
    // stays `Attached` at both cardinalities — an image was attached is the fact,
    // and a replacement is that fact preceded by a removal.
    attachCmd: (isSingle(c) ? "Set" : "Attach") ++ subject,
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

// What the VIEW holds, as against what an event's reference field holds. An
// event names a file; a view holds that file together with the text that goes
// with it, because a cell renderer is handed a field and a value and never the
// row — so a caption in a sibling field is a caption no cell can draw.
//
// Read off the reference type by name, as `contentArgOf` is. A host attaching
// something the vocabulary has no composite for keeps the bare reference, which
// is the shape it has today rather than a guess at one it does not.
let viewTypeOf = (c: config): string =>
  refTypeOf(c)->String.includes("Image") ? "Reventless.CaptionedImage.t" : refTypeOf(c)

// The collection field a member-selecting command picks out of. Named for the
// plural of the attachment field, which is what the view calls it.
let setFieldOf = (c: config): string => c.file ++ "s"

/**
The type a command field takes when it means *select one of the ones I have*
rather than *here is a new file*.

This is the distinction the whole graft used to be unable to make. Remove,
choose-primary and caption all name a reference the row already holds, and all
three were typed as the uploadable they select among — so a UI reading the
declaration bound an upload input to each of them, which on a remove command
offers the caller the one thing it cannot do.

`Single` declares no such field at all, so this is only ever reached for the
commands where a choice genuinely exists.

Spelled as a reference to a binding rather than inline: an `@s.matches(…)`
attribute has to fit on one line to parse, and the call with both names in it
does not — which is also the better shape, since the collection is one answer
and three inline copies are three chances for one to name a field that has moved.
*/
let selectionBinding = "selected"

let selectionTypeOf = (_c: config): string => `@s.matches(${selectionBinding}) string`

// What the members are, as the selection's own declaration states it — so a form
// drawing a picker shows thumbnails rather than a list of paths, without having
// to reach the collection field's element type.
//
// Read off the reference type by name, which is the only thing this module ever
// does. A host attaching something the vocabulary has no word for gets no
// content stated, and a reader falls back to its own rules — which is the honest
// answer rather than a guess with a default in it.
let contentArgOf = (c: config): string => {
  let ref = refTypeOf(c)
  if ref->String.includes("Image") {
    `~content=Reventless.Semantic.Id.imageRef, `
  } else if ref->String.includes("File") {
    `~content=Reventless.Semantic.Id.fileRef, `
  } else {
    ""
  }
}

// `@authorize` is the host's policy, so an absent one emits nothing at all rather
// than a permissive default — a graft that silently declared "anyone" would be
// worse than one that declares nothing.
//
// The rule survives being emitted as an annotation because the PPX lowers it
// into a `switch` whose arms are ordinary expressions: `AllowGroupz` does not
// compile. A stripped-before-the-typechecker attribute had no such second
// chance, which is why the states go out through `commandTransition` below,
// where the compiler resolves them.
let commandAttributes = (c: config): string =>
  switch c.authorize {
  | Some(a) => `  | @authorize(${a})\n  `
  | None => "  | "
  }

// The four commands' `commandTransition`, emitted whole because this graft's
// slice is a file the trait writes.
//
// The states arrive as config either way; what changes is where they land. In
// the removed `@transition([Products.Listed])` they were stripped before the
// typechecker and matched as strings at assembly; in `Guards([Products.Listed])` they are
// constructor references the compiler resolves, so a config typo is a build
// error naming it. Same input, and the difference is only who checks it.
// Every command this graft declares, in declaration order. `SetPrimary` is
// absent for a bounded set — the one thing that changes the *shape* of the
// emitted surface rather than a rule inside it — and every emission below reads
// this list rather than repeating the condition.
let commandNames = (c: config): array<string> => {
  let n = namesOf(c)
  isSingle(c)
    ? [n.attachCmd, n.removeCmd, n.setAltTextCmd]
    : [n.attachCmd, n.removeCmd, n.setPrimaryCmd, n.setAltTextCmd]
}

let commandTransitionBinding = (c: config): array<string> => {
  let arms = commandNames(c)->Array.map(cmd => `  | ${cmd}(_)`)->Array.join("\n")
  // The enum's *type*, which `lifecycleType` names. Absent leaves the marker,
  // and the marker does not compile — which is the honest outcome for a graft
  // that declared the states its commands are legal in and not the type they
  // are constructors of. A guess here would compile against whatever enum the
  // view happens to have first.
  let lifecycleType = switch c.lifecycleType {
  | Some(t) => `${c.view}.${t}`
  | None => `${c.view}.<lifecycle>  // TODO(graft): the enum's name`
  }
  switch c.transition {
  | Some(states) => [
      `type lifecycleState = ${lifecycleType}`,
      `let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {`,
      `  open Reventless.Transition`,
      `  switch command {`,
      arms ++ ` =>`,
      `    Guards([${states->Array.join(", ")}])`,
      `  }`,
      `}`,
      ``,
    ]
  | None => [
      `// TODO(graft): the states this host allows its attachment set to change in,`,
      `// as constructors of the linked view's lifecycle enum. Delete this binding`,
      `// outright if the answer is "any state" — the framework's default says so.`,
      `//`,
      `//   type lifecycleState = ${c.view}.<lifecycle>`,
      `//   let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {`,
      `//     open Reventless.Transition`,
      `//     switch command {`,
      arms->String.replaceAll("  | ", "//     | ") ++ ` =>`,
      `//       Guards([${c.view}.<State>])`,
      `//     }`,
      `//   }`,
      ``,
    ]
  }
}

let lines = (ls: array<string>) => ls->Array.join("\n")

// ── The slice spec ───────────────────────────────────────────────────────────

let sliceSpec = (c: config): string => {
  let n = namesOf(c)
  let ref = refTypeOf(c)
  let sel = selectionTypeOf(c)
  let single = isSingle(c)
  let attrs = commandAttributes(c)
  let createdArm =
    c.createdCarriesEntityId->Option.getOr(true)
      ? `  | ${c.created}({ ${c.entityId}: string})`
      : `  | ${c.created}`
  // Present only where a choice exists. A bounded set has one member, so
  // nothing consumes or emits a primary — and the trait's rules never produce
  // the fact, so listing the event would declare one nothing can write.
  let primaryArm = (prefix: string) =>
    single ? [] : [`  | ${n.primarySet}({ ${prefix}${c.file}: ${ref}})`]
  let headline =
    single
      ? [
          `// ${n.slice} StateChangeSlice: ${c.entity}'s single attachment — set it, remove`,
          `// it, caption it. A graft of the Attachments trait; the set's rules are the`,
        ]
      : [
          `// ${n.slice} StateChangeSlice: ${c.entity}'s attachment set — attach, remove,`,
          `// choose the primary, caption. A graft of the Attachments trait; the rules are`,
        ]
  lines([
    ...headline,
    `// trait's and are asserted by its conformance suite, bound in the tests.`,
    `//`,
    `// Emitted by the trait. Everything below is this host's own vocabulary, so it is`,
    `// ordinary source from here on — edit it freely.`,
    ``,
    `@@reventless.spec`,
    ``,
    `@schema`,
    `type consumedEvent =`,
    createdArm,
    `  | ${n.attached}({ ${c.file}: ${ref}})`,
    `  | ${n.removed}({ ${c.file}: ${ref}})`,
    ...primaryArm(""),
    `  | ${n.altTextSet}({ ${c.file}: ${ref}, altText: string})`,
    `  // TODO(graft): add the events this host's own refusal turns on — whatever`,
    `  // moves it into a state where attachments may not be changed.`,
    ``,
    ...(single
      ? [
          `// One reference field, on ${n.attachCmd}, and it accepts a new file — so`,
          `// it is typed as the uploadable it is and a form binds an upload input to it.`,
          `// Neither other command names a reference: with one attachment there is`,
          `// nothing to choose between, and asking a caller to name it would be asking`,
          `// them to repeat what the row already says.`,
        ]
      : [
          `// The reference fields divide into two kinds, and the division is the point.`,
          `// The one on ${n.attachCmd} accepts a new file, so it is typed as the`,
          `// uploadable it is and a form binds an upload input to it. The others name a`,
          `// file the row ALREADY holds, so they are typed as selections out of`,
          `// \`${setFieldOf(c)}\` and a form offers those instead of an uploader.`,
          `//`,
          `// Bound once rather than spelled three times: the collection is one answer,`,
          `// and three copies are three chances for one to name a field that has moved.`,
          `let ${selectionBinding} = Reventless.MemberRef.of_(~view="${c.view}", ${contentArgOf(
              c,
            )}~field="${setFieldOf(c)}")`,
          ``,
        ]),
    `@schema`,
    `type command =`,
    `${attrs}${n.attachCmd}({ ${c.entityId}: string, ${c.file}: ${ref}, altText?: string})`,
    // The bounded set's remove names nothing. This is the reported defect in its
    // purest form — the old command asked for an upload in order to delete.
    single
      ? `${attrs}${n.removeCmd}({ ${c.entityId}: string})`
      : `${attrs}${n.removeCmd}({ ${c.entityId}: string, ${c.file}: ${sel}})`,
    ...(single ? [] : [`${attrs}${n.setPrimaryCmd}({ ${c.entityId}: string, ${c.file}: ${sel}})`]),
    single
      ? `${attrs}${n.setAltTextCmd}({ ${c.entityId}: string, altText: string})`
      : `${attrs}${n.setAltTextCmd}({ ${c.entityId}: string, ${c.file}: ${sel}, altText: string})`,
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
    ...primaryArm(`${c.entityId}: string, `),
    `  | ${n.altTextSet}({ ${c.entityId}: string, ${c.file}: ${ref}, altText: string})`,
    ``,
    ...commandTransitionBinding(c),
    `// The graft's own record of itself. Nothing else survives into a deployed`,
    `// plugin — the dependency and the rules alias are source-side — so without`,
    `// this a running estate cannot say where this slice came from.`,
    `let traits = [TraitAttachments.Attachments.declaration]`,
    ``,
  ])
}

// ── The slice body ───────────────────────────────────────────────────────────

let sliceBehavior = (c: config): string => {
  let n = namesOf(c)
  let single = isSingle(c)
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
    // A creation event that carries no id is a bare constructor, so a wildcard
    // payload does not compile against it. The spec above already branches on
    // this; the fold has to branch with it.
    c.createdCarriesEntityId->Option.getOr(true)
      ? `  | ${c.created}(_) => {...state, exists: true}`
      : `  | ${c.created} => {...state, exists: true}`,
    `  | ${n.attached}({${c.file}}) => fold(Attached({ref: ${c.file}, altText: None}))`,
    `  | ${n.removed}({${c.file}}) => fold(Removed({ref: ${c.file}}))`,
    ...(single
      ? []
      : [`  | ${n.primarySet}({${c.file}}) => fold(PrimarySet({ref: ${c.file}}))`]),
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
    // `Clear` is what a ref-less remove maps onto: the op that empties the set,
    // whatever it holds. Nothing here has to look the member up.
    ...(single
      ? [`  | ${n.removeCmd}({${c.entityId}}) => (${c.entityId}, Attachments.Clear)`]
      : [
          `  | ${n.removeCmd}({${c.entityId}, ${c.file}}) => (`,
          `      ${c.entityId},`,
          `      Attachments.Remove({ref: ${c.file}}),`,
          `    )`,
          `  | ${n.setPrimaryCmd}({${c.entityId}, ${c.file}}) => (`,
          `      ${c.entityId},`,
          `      Attachments.SetPrimary({ref: ${c.file}}),`,
          `    )`,
        ]),
    ...(single
      ? [
          `  | ${n.setAltTextCmd}({${c.entityId}, altText}) => (`,
          `      ${c.entityId},`,
          // Not punned: a single-field inline record whose field shares its name
          // with the variable filling it is read as a record copy, and the
          // anonymous type then escapes its constructor.
          `      Attachments.SetPrimaryAltText({altText: altText}),`,
          `    )`,
        ]
      : [
          `  | ${n.setAltTextCmd}({${c.entityId}, ${c.file}, altText}) => (`,
          `      ${c.entityId},`,
          `      Attachments.SetAltText({ref: ${c.file}, altText}),`,
          `    )`,
        ]),
    `  }`,
    ``,
    // `Some`/`None` for a bounded set only. `fact` is the trait's type and so
    // lists a primary at both cardinalities, but a graft with no primary command
    // can never decide one — and an arm that fabricated some other event to keep
    // the switch total would be writing a fact nothing happened.
    `let toEvent = (${c.entityId}, fact) =>`,
    `  switch fact {`,
    `  | Attachments.Attached({ref, altText}) =>`,
    `    ${single ? "Some(" : ""}${n.attached}({${c.entityId}, ${c.file}: ref, altText: ?altText})${single
        ? ")"
        : ""}`,
    `  | Attachments.Removed({ref}) => ${single
        ? `Some(${n.removed}({${c.entityId}, ${c.file}: ref}))`
        : `${n.removed}({${c.entityId}, ${c.file}: ref})`}`,
    ...(single
      ? [
          `  // Unreachable: no command of this graft chooses a primary, because a set`,
          `  // of one has nothing to choose between. It contributes no event.`,
          `  | Attachments.PrimarySet(_) => None`,
        ]
      : [`  | Attachments.PrimarySet({ref}) => ${n.primarySet}({${c.entityId}, ${c.file}: ref})`]),
    `  | Attachments.AltTextSet({ref, altText}) =>`,
    `    ${single ? "Some(" : ""}${n.altTextSet}({${c.entityId}, ${c.file}: ref, altText})${single
        ? ")"
        : ""}`,
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
    single
      ? `    switch state.attachments->Attachments.decide(~cardinality=Single, op) {`
      : `    switch state.attachments->Attachments.decide(op) {`,
    `    | Error(#NotAttached) => Error(${n.notAttached})`,
    single
      ? `    | Ok(facts) => Ok(facts->Array.filterMap(toEvent(${c.entityId}, _)))`
      : `    | Ok(facts) => Ok(facts->Array.map(toEvent(${c.entityId}, _)))`,
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
  let single = isSingle(c)
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
    ...(single
      ? []
      : [
          `  let primarySetC = (ref): ${n.slice}.consumedEvent => ${n.primarySet}({ ${c.file}: ref})`,
        ]),
    `  let altTextSetC = (ref, altText): ${n.slice}.consumedEvent =>`,
    `    ${n.altTextSet}({ ${c.file}: ref, altText})`,
    ``,
    `  let attach = ref => ${n.slice}.${n.attachCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    ...(single
      ? [`  let clear = ${n.slice}.${n.removeCmd}({ ${c.entityId}: "${id}"})`]
      : [
          `  let remove = ref => ${n.slice}.${n.removeCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
          `  let setPrimary = ref =>`,
          `    ${n.slice}.${n.setPrimaryCmd}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
        ]),
    single
      ? `  let setAltText = altText => ${n.slice}.${n.setAltTextCmd}({ ${c.entityId}: "${id}", altText})`
      : `  let setAltText = (ref, altText) =>\n    ${n.slice}.${n.setAltTextCmd}({ ${c.entityId}: "${id}", ${c.file}: ref, altText})`,
    ``,
    `  let attached = ref => ${n.slice}.${n.attached}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    `  let removed = ref => ${n.slice}.${n.removed}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
    ...(single
      ? []
      : [
          `  let primarySet = ref =>`,
          `    ${n.slice}.${n.primarySet}({ ${c.entityId}: "${id}", ${c.file}: ref})`,
        ]),
    `  let altTextSet = (ref, altText) =>`,
    `    ${n.slice}.${n.altTextSet}({ ${c.entityId}: "${id}", ${c.file}: ref, altText})`,
    `  let notAttached = ${n.slice}.${n.notAttached}`,
    `}`,
    ``,
    single
      ? `module Conformance = TraitAttachments.Attachments_Conformance.MakeSingle(Binding)`
      : `module Conformance = TraitAttachments.Attachments_Conformance.Make(Binding)`,
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

// The bounded set's projection, which is a different patch rather than the same
// one with a branch in it: with one attachment the view carries the value itself
// and no collection at all, so there is no set to fold over and no primary to
// put first. Three assignments.
//
// The removal and the caption both guard on the reference they name. A
// replacement decides two facts — the old leaves, then the new arrives — and the
// guard is what makes each arm depend only on the row it finds rather than on
// those two reaching the projection in the order they were decided.
let singleProjectionPatch = (c: config): patch => {
  let n = namesOf(c)
  {
    into: `StateViewSliceStream/${c.view}_Projection.res`,
    at: `the projection's \`switch\`, and one field on \`${c.view}\`'s state`,
    contents: lines([
      `// On the view's state, one field — the reference and its text, in one value.`,
      `// No collection: this entity holds one attachment, so the field a card, a`,
      `// gallery tile and a list cell read IS the whole of what it has.`,
      `//`,
      `//   ${c.file}?: ${viewTypeOf(c)},`,
      ``,
      `| ${n.attached}({${c.entityId}, ${c.file}, altText: ?altText}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    ...state,`,
      `    ${c.file}: {ref: ${c.file}, altText: ?altText},`,
      `  })`,
      `| ${n.removed}({${c.entityId}, ${c.file}}) =>`,
      `  Update(${c.entityId}, state =>`,
      `    // Guarded on the reference: a removal that names something this row no`,
      `    // longer holds — the first half of a replacement, arriving late — must not`,
      `    // blank the one it does.`,
      `    heldRef(state) == Some(${c.file}) ? {...state, ${c.file}: ?None} : state`,
      `  )`,
      `| ${n.altTextSet}({${c.entityId}, ${c.file}, altText}) =>`,
      `  Update(${c.entityId}, state =>`,
      `    switch state.${c.file} {`,
      `    | Some(held) if held.ref == ${c.file} => {...state, ${c.file}: {...held, altText}}`,
      `    | _ => state`,
      `    }`,
      `  )`,
      ``,
      `// The reference this row holds, if it holds one. Named because both guards`,
      `// above ask the same question of a value that is no longer the reference itself.`,
      `let heldRef = (state: ${c.view}.state) => state.${c.file}->Option.map(held => held.ref)`,
    ]),
  }
}

let manyProjectionPatch = (c: config): patch => {
  let n = namesOf(c)
  let set = setFieldOf(c)
  {
    into: `StateViewSliceStream/${c.view}_Projection.res`,
    at: `the projection's \`switch\`, and one field on \`${c.view}\`'s state`,
    contents: lines([
      `// On the view's state, one field — the set, primary first.`,
      `//`,
      `// The primary is the FIRST member rather than a scalar beside the set. That is`,
      `// what a card, a gallery tile and a list cell read, so there is no second field`,
      `// to keep in step with the set and no arm that can forget to. The text rides`,
      `// inside each member for the same reason: a cell renderer is handed a field and`,
      `// a value and never the row, so a caption in a sibling field is one no cell can`,
      `// draw.`,
      `//`,
      `// What it costs, stated plainly: attachment order stops being readable off the`,
      `// view. The log still has it.`,
      `//`,
      `//   ${set}: array<${viewTypeOf(c)}>,`,
      ``,
      `// Appended, so the first attached is the primary until one is chosen.`,
      `| ${n.attached}({${c.entityId}, ${c.file}, altText: ?altText}) =>`,
      `  Update(${c.entityId}, state =>`,
      `    state.${set}->Array.some(m => m.ref == ${c.file})`,
      `      ? state`,
      `      : {`,
      `          ...state,`,
      `          ${set}: state.${set}->Array.concat([{ref: ${c.file}, altText: ?altText}]),`,
      `        }`,
      `  )`,
      `// Removing the head promotes the next member with no arm to say so.`,
      `| ${n.removed}({${c.entityId}, ${c.file}}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    ...state,`,
      `    ${set}: state.${set}->Array.filter(m => m.ref != ${c.file}),`,
      `  })`,
      `| ${n.primarySet}({${c.entityId}, ${c.file}}) =>`,
      `  Update(${c.entityId}, state => primaryFirst(state, ${c.file}))`,
      `| ${n.altTextSet}({${c.entityId}, ${c.file}, altText}) =>`,
      `  Update(${c.entityId}, state => {`,
      `    ...state,`,
      `    ${set}: state.${set}->Array.map(m => m.ref == ${c.file} ? {...m, altText} : m),`,
      `  })`,
      ``,
      `// Choosing the primary is moving it to the front — the trait's rule, applied`,
      `// over the view's rows. The only arm that reorders; the rest leave the head`,
      `// where they found it.`,
      `let primaryFirst = (state: ${c.view}.state, chosen) => {`,
      `  ...state,`,
      `  ${set}: TraitAttachments.Attachments_Rules.primaryFirst(`,
      `    ~chosen,`,
      `    ~members=state.${set},`,
      `    ~ref=m => m.ref,`,
      `  ),`,
      `}`,
    ]),
  }
}

let projectionPatch = (c: config): patch =>
  isSingle(c) ? singleProjectionPatch(c) : manyProjectionPatch(c)

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
