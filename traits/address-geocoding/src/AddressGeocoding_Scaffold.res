/**
The graft's spec surface, written rather than transcribed.

This trait grafts onto an **aggregate**, and that decides the split. An
aggregate's event stream is entity-scoped, so the trait's four facts and its two
`@noApi` report commands are real constructors a host splices — see
`AddressGeocoding.events` / `.reportCommands`. What is left for a scaffolder is
the half a spread cannot reach: the outbound slice, which is a whole component
the host does not have yet, and the arms that belong inside files the host
already owns.

So the shape here is the mirror of `Attachments_Scaffold`. That one writes
almost everything, because a DCB graft *is* a new slice. This one writes three
files and prints three patches, because most of an aggregate graft is either
spliced by the compiler or interleaved with the host's own state machine.

**Why this is code and not a template.** A `.res.tpl` compiles nowhere and is
checked by nothing. The fragments this module replaces had already drifted:
`OutboundTranslationSlice.res.tpl` declared the creation event as
`{{Created}}({ {{subject}}: string})`, and the one host that applied it carries
`Registered({email: string, address: string})` — a payload the template had no
way to express and no way to notice it was missing. Here it is `createdFields`,
and a host that needs it says so.

**What it does not do.** It never writes the host's policy. Which states an
address may be changed in, who may change it, what a host's own commands refuse
— those are `commandTransition` and `@authorize` over the host's own lifecycle,
which a trait cannot know. They are config when the host supplies them and absent
when it does not.
*/

/**
The names a graft needs, and nothing else.

Everything here is a name or a literal spliced into a declaration. Nothing here
is control flow — that boundary is what keeps this a scaffolder rather than a
worse ReScript.
*/
@schema
type config = {
  /** The host entity, capitalised: `"Customer"`. */
  entity: string,
  /** Its id field: `"customerId"`. */
  entityId: string,
  /** The host event that brings the entity into existence: `"Registered"`. It is
      one of the slice's two triggers, because an entity created with an address
      has never been geocoded. */
  created: string,

  /**
  What this host calls the thing being geocoded, lowercase: `"address"`.

  Defaults to `"address"`, and that default is load-bearing rather than cosmetic:
  `AddressGeocoding.events` fixes both the word and the type `string`, and a
  spread cannot rename what it splices. A host that keeps the default gets the
  aggregate half for one line; a host that calls it `"site"` or `"pickupPoint"`
  gets the same rules and the same conformance suite, with the declarations
  spelled out. The emitted patch says which of the two you are getting.
  */
  subject?: string,

  /**
  The creation event's payload *beyond* the subject, as declarations:
  `["email: string"]`.

  Carried because the slice re-declares the events it consumes, and a consumed
  declaration that drops a field the host publishes is a decode this trait would
  have caused and could not see.
  */
  createdFields?: array<string>,
  /** The same fields as fixture literals — `["email: \"alice@x.y\""]` — for the
      conformance binding's histories. Omitted ⇒ omitted from the fixtures, which
      only compiles when `createdFields` is omitted too. */
  createdValues?: array<string>,

  /** The slice component's name. Defaults to `Geocode<Entity><Subject>`. */
  slice?: string,
  /** The external box the Event Graph draws. Defaults to `"Geocoder"`; a host on
      a named provider says so — `"AwsLocation"`. */
  externalSystem?: string,
  /** The read model the projection patch is addressed to. Defaults to
      `<Entity>s`. */
  view?: string,

  /** Two subjects that differ, for the histories in which the address changes.
      Defaulted when absent — they are test data, not a decision. */
  subjectA?: string,
  subjectB?: string,
}

/** A file the graft owns outright, written to disk. */
type file = {path: string, contents: string}

/** Arms for a file the host already owns. Printed for a human to place, never
    written: inserting into an existing ordered `switch` is an AST operation, and
    a text splice into the wrong arm is a bug the compiler cannot see. */
type patch = {into: string, at: string, contents: string}

type output = {files: array<file>, patches: array<patch>}

// ── The vocabulary, derived once ─────────────────────────────────────────────

type names = {
  /** `"address"` */
  subject: string,
  /** `"Address"` */
  subjectCap: string,
  /** `"GeocodeCustomerAddress"` */
  slice: string,
  /** `"Customers"` */
  view: string,
  /** `"AddressUpdated"`, `"AddressLocated"`, `"AddressUnresolvable"` */
  updated: string,
  located: string,
  unresolvable: string,
  /** `"UpdateAddress"`, `"SetAddressLocation"`, `"MarkAddressUnresolvable"` */
  updateCmd: string,
  suppliedPairCmd: string,
  markUnresolvableCmd: string,
  /** True when the host keeps the trait's own word and type, and can therefore
      splice `AddressGeocoding.events` and `.reportCommands` instead of
      declaring them. */
  spreadable: bool,
}

let capitalise = s =>
  s->String.charAt(0)->String.toUpperCase ++ s->String.slice(~start=1, ~end=s->String.length)

let namesOf = (c: config): names => {
  let subject = c.subject->Option.getOr("address")
  let subjectCap = capitalise(subject)
  {
    subject,
    subjectCap,
    slice: c.slice->Option.getOr("Geocode" ++ c.entity ++ subjectCap),
    view: c.view->Option.getOr(c.entity ++ "s"),
    updated: subjectCap ++ "Updated",
    located: subjectCap ++ "Located",
    unresolvable: subjectCap ++ "Unresolvable",
    updateCmd: "Update" ++ subjectCap,
    suppliedPairCmd: "Set" ++ subjectCap ++ "Location",
    markUnresolvableCmd: "Mark" ++ subjectCap ++ "Unresolvable",
    spreadable: subject == "address",
  }
}

let lines = (ls: array<string>) => ls->Array.join("\n")

/** The creation event's payload, subject last, as declarations or as literals.
    One helper for both so the two can never fall out of step. */
let createdPayload = (c: config, ~n: names, ~values: bool) => {
  let extra = values ? c.createdValues->Option.getOr([]) : c.createdFields->Option.getOr([])
  let own = values ? n.subject : n.subject ++ ": string"
  Array.concat(extra, [own])->Array.join(", ")
}

// ── The slice spec ───────────────────────────────────────────────────────────

let sliceSpec = (c: config): string => {
  let n = namesOf(c)
  lines([
    `// ${n.slice}: turns the ${n.subject} into a point and reports back to ${c.entity} —`,
    `// \`SetLocation\` when sure, \`${n.markUnresolvableCmd}\` when not. Neither is`,
    `// callable from the API.`,
    `//`,
    `// Emitted by the address-geocoding trait. Everything below is this host's own`,
    `// vocabulary, so it is ordinary source from here on — edit it freely.`,
    ``,
    `@@reventless.spec`,
    ``,
    `// Only the triggers. The event that carries ${n.subject} and point together is`,
    `// deliberately absent: the slice stands down when a client geocoded for itself,`,
    `// and the conformance suite asserts that this set is no wider than \`collect\`.`,
    `@schema`,
    `type consumedEvent =`,
    `  | ${c.created}({${createdPayload(c, ~n, ~values=false)}})`,
    `  | ${n.updated}({${n.subject}: string})`,
    ``,
    `@schema`,
    `type outboundItem = {${c.entityId}: string, ${n.subject}: string}`,
    ``,
    `@schema`,
    `type inboundCommand =`,
    `  | SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})`,
    `  | ${n.markUnresolvableCmd}({${n.subject}: string, reason: string})`,
    ``,
    `// Retries are for a geocoder that is down, not one that has answered.`,
    `let maxRetries = 3`,
    `let heartbeatInterval = 60`,
    `let targetName = Some("${c.entity}")`,
    ``,
    `// The ${c.entity} aggregate by its Spec.name; an outbound slice could once only`,
    `// read its plugin's DCB event log.`,
    `let sourceNames = ["${c.entity}"]`,
    ``,
    `// Drawn as an external box outside this plugin in the Event Graph.`,
    `let externalSystem = Some("${c.externalSystem->Option.getOr("Geocoder")}")`,
    ``,
    `// The trait says what it reaches for; this host only names it. Spelling the`,
    `// capability here instead would be the one part of the graft nothing checks —`,
    `// an unprovisioned geocoder answers \`Unavailable\`, the retries run out, and`,
    `// every ${n.subject} is recorded as permanently unresolvable with no error raised.`,
    `let capabilityNeeds = TraitAddressGeocoding.AddressGeocoding.capabilityNeeds`,
    `// The graft's own record of itself. Nothing else survives into a deployed`,
    `// plugin — the dependency, the spread and the conformance binding are all`,
    `// source-side — so without this a running estate cannot say where this`,
    `// component came from.`,
    `let traits = [TraitAddressGeocoding.AddressGeocoding.declaration]`,
    ``,
  ])
}

// ── The slice body ───────────────────────────────────────────────────────────

let sliceTranslation = (c: config): string => {
  let n = namesOf(c)
  // Double-quoted rather than interpolated: these lines carry `${…}` and
  // backticks that belong to the emitted code, not to this file.
  let key = "`${sourceId}:${" ++ n.subject ++ "}`"
  let collectArm = event =>
    "  | " ++
    event ++
    "({" ++
    n.subject ++
    "}) => [(" ++
    key ++
    ", {" ++
    c.entityId ++
    ": sourceId, " ++
    n.subject ++
    "})]"
  lines([
    `@@reventless.translation`,
    ``,
    `// Keyed by entity *and* ${n.subject}: keying by entity alone would make a later`,
    `// ${n.subject} change look like work already done. \`~sourceId\` is the entity id,`,
    `// which an aggregate's event payload does not repeat.`,
    `let collect = (event, ~sourceId) =>`,
    `  switch event {`,
    collectArm(c.created),
    collectArm(n.updated),
    `  }`,
    ``,
    `// Asking the geocoder and reading its answer are the trait's — including the`,
    `// confidence rule, and the rule that an outage is not a verdict. The two`,
    `// commands the answer is reported through are this host's.`,
    `module Geocode = TraitAddressGeocoding.AddressGeocoding_Translate`,
    ``,
    `let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) =>`,
    `  (`,
    `    await Geocode.translate(`,
    `      ~text=item.${n.subject},`,
    `      ~capabilities,`,
    `      ~located=(~point, ~resolvedFrom) => SetLocation({location: point, resolvedFrom}),`,
    `      // A verdict for a human, not a coordinate.`,
    `      ~unresolvable=(~subject, ~reason) =>`,
    `        ${n.markUnresolvableCmd}({${n.subject}: subject, reason}),`,
    `    )`,
    `  )->Result.map(command => Some((item.${c.entityId}, command)))`,
    ``,
    `// The budget is spent and the geocoder never answered. Recording the verdict`,
    `// beats leaving the TODO pending forever — and it is why the capability must be`,
    `// declared, since an unprovisioned geocoder reaches here every time.`,
    `let onExhausted = (_id, item: outboundItem, ~lastError) =>`,
    `  Some((`,
    `    item.${c.entityId},`,
    `    ${n.markUnresolvableCmd}({`,
    `      ${n.subject}: item.${n.subject},`,
    `      reason: Geocode.exhaustedReason(lastError),`,
    `    }),`,
    `  ))`,
    ``,
  ])
}

// ── The conformance binding ──────────────────────────────────────────────────
//
// Emitted whole and final. It is pure name-mapping — every line of it is already
// in the config — and it is the file a host would otherwise write by hand with
// nothing checking that the names line up.

let conformanceBinding = (c: config): string => {
  let n = namesOf(c)
  let subjectA = c.subjectA->Option.getOr("Stephansplatz 1, Vienna")
  let subjectB = c.subjectB->Option.getOr("Kärntner Straße 1, Vienna")
  let createdValue = `${c.created}({${createdPayload(c, ~n, ~values=true)}})`
  lines([
    `// The address-geocoding trait's conformance suite, bound to \`${c.entity}\`. The`,
    `// graft rules are asserted by the trait; this file only says what the host calls`,
    `// things. Emitted whole: every name here is one the graft already declared.`,
    ``,
    `module Binding = {`,
    `  type subject = string`,
    `  let subjectText = s => s`,
    `  let subjectA = "${subjectA}"`,
    `  let subjectB = "${subjectB}"`,
    `  let posture = TraitAddressGeocoding.AddressGeocoding.WritesBack`,
    ``,
    `  module Spec = ${c.entity}`,
    `  module Behavior = ${c.entity}_Behavior`,
    ``,
    `  let created = ${n.subject} => [${c.entity}.${createdValue}]`,
    `  let subjectChanged = ${n.subject} => ${c.entity}.${n.updated}({${n.subject}: ${n.subject}})`,
    `  let located = (~point, ~resolvedFrom) =>`,
    `    ${c.entity}.LocationSet({location: point, resolvedFrom})`,
    `  let unresolvable = (~subject, ~reason) =>`,
    `    ${c.entity}.${n.unresolvable}({${n.subject}: subject, reason})`,
    `  let setLocation = (~point, ~resolvedFrom) =>`,
    `    ${c.entity}.SetLocation({location: point, resolvedFrom})`,
    `  let markUnresolvable = (~subject, ~reason) =>`,
    `    ${c.entity}.${n.markUnresolvableCmd}({${n.subject}: subject, reason})`,
    ``,
    `  module Slice = {`,
    `    include ${n.slice}`,
    `    let collect = ${n.slice}_Translation.collect`,
    `  }`,
    `  let translate = ${n.slice}_Translation.translate`,
    `  let item = (~entityId, ~subject) => {`,
    `    ${n.slice}.${c.entityId}: entityId,`,
    `    ${n.subject}: subject,`,
    `  }`,
    `  // Every event type the slice consumes appears here — the consumed set may`,
    `  // not be wider than its triggers, and the suite checks exactly that.`,
    `  let triggers = ${n.subject} => [`,
    `    ${n.slice}.${createdValue},`,
    `    ${n.slice}.${n.updated}({${n.subject}: ${n.subject}}),`,
    `  ]`,
    `  // The stand-down, as a real constructor rather than a type name: a`,
    `  // misspelled name would pass the assertion for the wrong reason.`,
    `  let standsDownOn = [`,
    `    ${c.entity}.${n.located}({${n.subject}: subjectA, location: {lat: 0.0, lng: 0.0}}),`,
    `  ]`,
    `  let isLocation = (cmd: ${n.slice}.inboundCommand) =>`,
    `    switch cmd {`,
    `    | SetLocation(_) => true`,
    `    | ${n.markUnresolvableCmd}(_) => false`,
    `    }`,
    `  let isVerdict = (cmd: ${n.slice}.inboundCommand) => !isLocation(cmd)`,
    `}`,
    ``,
    `module Conformance = TraitAddressGeocoding.AddressGeocoding_Conformance.Make(Binding)`,
    ``,
    `Conformance.register()`,
    ``,
  ])
}

// ── The aggregate patch ──────────────────────────────────────────────────────
//
// Printed, not written: the aggregate exists, and its command and event unions
// are the host's own. Which of the two forms below is printed is the one
// decision this module makes rather than transcribes — see `names.spreadable`.

// The four commands' arms for the host's `commandTransition`, which is where an
// aggregate graft's policy now lives.
//
// The two reports are answered outright — `Unrestricted` is a trait fact, not a
// host choice: a report must be legal in every state, or an answer landing after
// the entity moved on parks a TODO row forever. The two public commands are the
// host's call, so they are printed as a marked hole. That split is the same one
// the whole scaffold runs on, and it is why an attribute could not serve here:
// one cannot be attached to a constructor the host did not declare.
let transitionArms = (c: config): array<string> => {
  let n = namesOf(c)
  [
    `// The switch is exhaustive, so these four arms are not optional — the`,
    `// compiler will name whichever you leave out.`,
    `| SetLocation(_) | ${n.markUnresolvableCmd}(_) => Unrestricted`,
    `// TODO(graft): the states this host allows an ${n.subject} change in, as`,
    `// constructors of the linked view's lifecycle enum — the compiler resolves`,
    `// them, so a misspelling is a build error rather than a dead menu entry.`,
    `//`,
    `//   type lifecycleState = ${n.view}.<lifecycle>`,
    `//`,
    `//   | ${n.updateCmd}(_) | ${n.suppliedPairCmd}(_) => Guards([${n.view}.<State>])`,
  ]
}

let aggregatePatch = (c: config): patch => {
  let n = namesOf(c)
  let commandArms = n.spreadable
    ? [
        `  // The two public ${n.subject} commands, spliced from the trait. Their`,
        `  // lifecycle guard lives in \`commandTransition\` below, not on the`,
        `  // constructors — which is what lets the trait own them at all.`,
        `  | ...TraitAddressGeocoding.AddressGeocoding.addressCommands`,
        `  // The two the slice reports through, likewise spliced. Both are \`@noApi\`,`,
        `  // and the exclusion is recorded on each member, so it survives the spread`,
        `  // and neither is published.`,
        `  | ...TraitAddressGeocoding.AddressGeocoding.reportCommands`,
      ]
    : [
        `  // Spelled out rather than spliced: this host calls the subject`,
        `  // "${n.subject}", and a spread cannot rename what it splices.`,
        `  | ${n.updateCmd}({${n.subject}: string})`,
        `  | ${n.suppliedPairCmd}({${n.subject}: string, location: Reventless.GeoPoint.t})`,
        `  // Deliberately unguarded — legal in every state, \`Ok([])\` on a retired`,
        `  // entity, so an in-flight answer never parks a TODO row forever.`,
        `  | @noApi SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})`,
        `  | @noApi ${n.markUnresolvableCmd}({${n.subject}: string, reason: string})`,
      ]
  let eventArms = n.spreadable
    ? [
        `  // The graft's four facts, spliced from the trait: \`${n.updated}\`,`,
        `  // \`LocationSet\`, \`${n.located}\`, \`${n.unresolvable}\`. They are matched`,
        `  // unqualified in \`evolve\` and in the projections, and sury splices the schema`,
        `  // flat, so the wire format is what hand-written arms produced.`,
        `  | ...TraitAddressGeocoding.AddressGeocoding.events`,
      ]
    : [
        `  | ${n.updated}({${n.subject}: string})`,
        `  // \`resolvedFrom\` is provenance, not the ${n.subject} of record; it is what`,
        `  // makes "is the pin still current?" decidable.`,
        `  | LocationSet({location: Reventless.GeoPoint.t, resolvedFrom: string})`,
        `  // Both halves from a client. Not \`${n.updated}\` + \`LocationSet\`: the slice`,
        `  // collects the former, and this event is not in its consumed set — the`,
        `  // stand-down.`,
        `  | ${n.located}({${n.subject}: string, location: Reventless.GeoPoint.t})`,
        `  // A fact, not an absence: \`location: None\` already means "not looked up yet".`,
        `  | ${n.unresolvable}({${n.subject}: string, reason: string})`,
      ]
  {
    into: `Aggregate/${c.entity}.res`,
    at: n.spreadable
      ? `\`type command\` and \`type event\` — two spread lines and two commands`
      : `\`type command\` and \`type event\` — spelled out, because the subject is not \`address\``,
    contents: lines(
      Array.concatMany(
        [`// --- type command ------------------------------------------------------------`],
        [
          commandArms,
          [``, `// --- type event --------------------------------------------------------------`],
          eventArms,
          [``, `// --- commandTransition -------------------------------------------------------`],
          transitionArms(c),
        ],
      ),
    ),
  }
}

// ── The aggregate behavior patch ─────────────────────────────────────────────

let behaviorPatch = (c: config): patch => {
  let n = namesOf(c)
  {
    into: `Aggregate/${c.entity}_Behavior.res`,
    at: `the state's fields, the \`evolve\` and \`decide\` switches, and two helpers`,
    contents: lines([
      `module Guards = TraitAddressGeocoding.AddressGeocoding_Guards`,
      ``,
      `// --- state fields ------------------------------------------------------------`,
      `// Two fields, because there are three states and one \`option\` holds two: never`,
      `// asked, a point found, and the ${n.subject} tried and found wanting (a`,
      `// resolved-from, no point). Host-owned rather than a trait record: an`,
      `// aggregate's state is snapshotted, so a trait release that reshaped it would`,
      `// be a migration. Invariant every arm preserves: \`locationResolvedFrom\` is`,
      `// \`None\` or equal to \`${n.subject}\`.`,
      `      location: option<Reventless.GeoPoint.t>,`,
      `      locationResolvedFrom: option<string>,`,
      ``,
      `// --- evolve arms -------------------------------------------------------------`,
      `  // A new ${n.subject} invalidates what was known; dropping both puts the row`,
      `  // back in front of the slice.`,
      `  | (Active(s), ${n.updated}({${n.subject}})) =>`,
      `    Active({...s, ${n.subject}, location: None, locationResolvedFrom: None})`,
      `  | (Active(s), LocationSet({location, resolvedFrom})) =>`,
      `    Active({...s, location: Some(location), locationResolvedFrom: Some(resolvedFrom)})`,
      `  // The caller supplied the pair, so there is nothing left to resolve.`,
      `  | (Active(s), ${n.located}({${n.subject}, location})) =>`,
      `    Active({`,
      `      ...s,`,
      `      ${n.subject},`,
      `      location: Some(location),`,
      `      locationResolvedFrom: Some(${n.subject}),`,
      `    })`,
      `  // Recording the ${n.subject} keeps the slice from handing it back for another round.`,
      `  | (Active(s), ${n.unresolvable}({${n.subject}})) =>`,
      `    Active({...s, location: None, locationResolvedFrom: Some(${n.subject})})`,
      ``,
      `// --- the trait's view, and what it decides ------------------------------------`,
      `// Built per call, because the inline record of \`Active\` cannot escape its`,
      `// constructor.`,
      `let resolution = (${n.subject}, location, locationResolvedFrom): Guards.resolution => {`,
      `  subject: ${n.subject},`,
      `  location,`,
      `  resolvedFrom: locationResolvedFrom,`,
      `}`,
      ``,
      `let appended = (verdict, event) =>`,
      `  switch verdict {`,
      `  | Guards.Append => Ok([event])`,
      `  | Guards.Ignore => Ok([])`,
      `  }`,
      ``,
      `// --- decide arms -------------------------------------------------------------`,
      `  | (Active(s), ${n.updateCmd}({${n.subject}})) =>`,
      `    Guards.onSubjectUpdate(`,
      `      resolution(s.${n.subject}, s.location, s.locationResolvedFrom),`,
      `      ~subject=${n.subject},`,
      `    )->appended(${n.updated}({${n.subject}: ${n.subject}}))`,
      ``,
      `  | (Active(s), ${n.suppliedPairCmd}({${n.subject}, location})) =>`,
      `    Guards.onSuppliedPair(`,
      `      resolution(s.${n.subject}, s.location, s.locationResolvedFrom),`,
      `      ~subject=${n.subject},`,
      `      ~location,`,
      `    )->appended(${n.located}({${n.subject}, location}))`,
      ``,
      `  | (Active(s), SetLocation({location, resolvedFrom})) =>`,
      `    Guards.onLocationReport(`,
      `      resolution(s.${n.subject}, s.location, s.locationResolvedFrom),`,
      `      ~location,`,
      `      ~resolvedFrom,`,
      `    )->appended(LocationSet({location, resolvedFrom}))`,
      ``,
      `  | (Active(s), ${n.markUnresolvableCmd}({${n.subject}, reason})) =>`,
      `    Guards.onUnresolvableReport(`,
      `      resolution(s.${n.subject}, s.location, s.locationResolvedFrom),`,
      `      ~subject=${n.subject},`,
      `    )->appended(${n.unresolvable}({${n.subject}, reason}))`,
      ``,
      `  // TODO(graft): the two report commands must be legal in every state this`,
      `  // host has. On a retired entity, swallow rather than refuse — an in-flight`,
      `  // answer landing after retirement would otherwise park a TODO row forever.`,
      `  //`,
      `  //   | (Retired(_), SetLocation(_)) => Ok([])`,
      `  //   | (Retired(_), ${n.markUnresolvableCmd}(_)) => Ok([])`,
      ``,
    ]),
  }
}

// ── The projection patch ─────────────────────────────────────────────────────

let projectionPatch = (c: config): patch => {
  let n = namesOf(c)
  {
    into: `ReadModelStream/${n.view}_Projections.res`,
    at: `the projection's \`switch\`, and one field on \`${n.view}\`'s state`,
    contents: lines([
      `// On the view's state, one field:`,
      `//`,
      `//   geolocation: Reventless.Geolocation.t,`,
      `//`,
      `// Three arms rather than \`option<GeoPoint.t>\`: \`Pending\` carries the ${n.subject}`,
      `// asked about, so a stale answer is detectable from the row alone.`,
      ``,
      `// On the creation arm's default state:`,
      `//   geolocation: Pending({requestedFor: ${n.subject}})`,
      ``,
      `// A new ${n.subject} invalidates the pin: back to Pending for the new one.`,
      `| ${n.updated}({${n.subject}}) =>`,
      `  Update(id, state => {`,
      `    ...state,`,
      `    ${n.subject},`,
      `    geolocation: Pending({requestedFor: ${n.subject}}),`,
      `  })`,
      `| LocationSet({location}) =>`,
      `  Update(id, state => {...state, geolocation: Located({point: location})})`,
      `// The client supplied the pair, so no geocode is owed.`,
      `| ${n.located}({${n.subject}, location}) =>`,
      `  Update(id, state => {...state, ${n.subject}, geolocation: Located({point: location})})`,
      `| ${n.unresolvable}({reason: why}) =>`,
      `  Update(id, state => {...state, geolocation: Unresolvable({reason: why})})`,
    ]),
  }
}

/**
Emit a graft.

Three files written, three patches printed — the mirror of the attachments
scaffold, and the mirror for a reason: an aggregate host already owns the files
most of this graft lands in, and the compiler splices the rest.

The files are the host's from the moment they land — nothing regenerates them,
and nothing compares against them later.
*/
let emit = (~config: config, ~into: string, ~tests: string): output => {
  let n = namesOf(config)
  {
    files: [
      {
        path: `${into}/OutboundTranslationSlice/${n.slice}.res`,
        contents: sliceSpec(config),
      },
      {
        path: `${into}/OutboundTranslationSlice/${n.slice}_Translation.res`,
        contents: sliceTranslation(config),
      },
      {
        path: `${tests}/AddressGeocodingConformance_GWT.res`,
        contents: conformanceBinding(config),
      },
    ],
    patches: [aggregatePatch(config), behaviorPatch(config), projectionPatch(config)],
  }
}
