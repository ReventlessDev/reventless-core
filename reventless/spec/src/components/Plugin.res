/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

/**
Classifies the business role of a plugin, carried on `pluginDefinition` so the
plugin-lifecycle read model can segregate infrastructure/commercial/marketplace
plugins from domain plugins in the admin Plugins view. Absent (on definitions
persisted before this field existed) is read as `Domain`.

Canonical here in `reventless-spec` because `pluginDefinition` (a `@schema` type
nested in the lifecycle Message union) needs the sury schema; `ReventlessCore.Plugin_BuiltHook`
re-exports this same type for its deploy-time metadata registry.
*/
@schema
type pluginKind =
  | Domain
  | PlatformInfrastructure
  | Commercial
  | Marketplace

/**
Describes an extension point exported by a plugin.
Included in the plugin's `pluginDefinition` for use by the gateway / host.
*/
@schema
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

/**
Describes an extension imported by a plugin (i.e. a connection to a host plugin's
extension point).
Included in the plugin's `pluginDefinition` for use by the host.
*/
@schema
type extensionDefinition = {
  name: string,
  extensionPointName: string,
  /**
  DCB EventLog source names this extension consumes. Convention: each entry is
  the `name` field of a peer plugin's `dcbEventLogDefinition` (i.e. `${peer}DcbEventLog`).
  The admin uses these to provision cross-plugin SNS subscriptions from peer DCB
  EventTopics → this plugin's EventCollector. `[]` for extensions that only consume
  ExtensionPoint EventTopics.
  */
  dcbSources: array<string>,
}

/**
Describes a DCB EventLog exposed by a plugin.
Included in the plugin's `pluginDefinition` so the admin can provision SNS
subscriptions from this plugin's DCB EventTopic to any peer plugin whose
extension references the DCB log by name.
*/
@schema
type dcbEventLogDefinition = {
  /** Service name carried in event meta — convention: `${plugin.name}DcbEventLog`. */
  name: string,
  /** SNS topic ARN for the DCB EventLog's EventTopic. */
  eventTopicArn: string,
}

/**
Protocol version declaration for a single extension point connection.

Carried in the `ConnectPlugin` handshake so the host can validate schema
compatibility before accepting the extension. Use `[]` when version
negotiation is not needed.
*/
// Protocol version declaration for a single extension point connection.
// Carried in the ConnectPlugin handshake so the host can validate compatibility.
@schema
type extensionProtocol = {
  extensionPointName: string,
  /** SemVer of the command schema the extension was compiled against. */
  commandVersion: string,
  /** SemVer of the event schema the extension was compiled against. */
  eventVersion: string,
}

/**
A GraphQL schema fragment contributed by a plugin.
Encoded as JSON for transport; protocol identifies the schema format (e.g. "graphql").
*/
@schema
type apiSchemaFragment = {encoded: string, protocol: string}

/**
The API a plugin's GraphQL fields are stitched into: the Domain API (the default —
application plugins) or the Platform API (platform-level plugins such as an inspector,
which contribute fields alongside the admin base). Serializes as the bare string
"Domain" / "Platform". Consumed by the schema-fragment registry to maintain one
cumulative schema per API.
*/
@schema
type apiTarget = Domain | Platform

// Sury's nullableAsOption creates T | undefined | null which fails jsonableValidation
// inside union variant payloads. js_nullable creates T | null (no undefined) which is
// JSON-safe and passes jsonableValidation in all contexts.
@module("sury/src/Sury.res.mjs") external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"
let apiSchemaFragmentOffloadSchema = Offload.optionSchema(~store="pluginApiFragments", apiSchemaFragmentSchema)
let dcbEventLogOptionSchema = _jsNullable(dcbEventLogDefinitionSchema, ())
// js_nullable creates T | null which passes sury's jsonableValidation inside union variant payloads.
let stringOptionSchema = _jsNullable(S.string, ())
let stringArrayOptionSchema = _jsNullable(S.array(S.string), ())
let boolOptionSchema = _jsNullable(S.bool, ())

// ── UI fragment manifest types ────────────────────────────────────────────────

@schema
type panelManifestEntry = {
  fragmentId: string,
  title: string,
  description: string,
  positions: array<string>,
  requiredAccess: @s.matches(stringOptionSchema) option<string>,
}

@schema
type menuEntry = {
  label: string,
  icon: @s.matches(stringOptionSchema) option<string>,
  group: @s.matches(stringOptionSchema) option<string>,
  sortOrder: int,
}

@schema
type pageManifestEntry = {
  fragmentId: string,
  title: string,
  menuEntry: menuEntry,
  requiredAccess: @s.matches(stringOptionSchema) option<string>,
}

@schema
type uiFragmentManifest = {
  remoteEntryUrl: string,
  panels: array<panelManifestEntry>,
  pages: array<pageManifestEntry>,
}

let uiFragmentManifestOptionSchema = _jsNullable(uiFragmentManifestSchema, ())

// ── Plugin structure types (component metadata for Auto UI and event graph) ──

@schema
type commandLevel = Collection | Instance

@schema
type fieldReference = {
  fieldName: string,
  entity: string,
  plugin: @s.matches(stringOptionSchema) option<string>,
}

@schema
type commandDef = {
  name: string,
  schema: string,
  level: commandLevel,
  aggregateIdField: @s.matches(stringOptionSchema) option<string>,
  mutationField: string,
  references: array<fieldReference>,
  /**
  Lifecycle states under which this command is meaningful. `None` means the command
  is always available (back-compat default). `Some([…])` lets AutoUI hide the
  command on rows whose lifecycle field is not in the set — see
  `queryableDef.lifecycleField` for how the row's state is located. `Some([])` is
  the defensive "never show" form.
  */
  allowedStates: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /**
  The single lifecycle state this command's handler writes — the command's *to*
  state, sibling of `allowedStates`' *from* set. Source: the
  `@targetState("Shipped")` command-variant annotation. `None` (absent
  annotation) is the back-compat default: AutoUI's board resolver then falls
  back to its name-stem heuristic. `Some("Shipped")` lets the resolver move a
  row by a declared transition instead of a guess. js_nullable for JSON safety,
  same as `allowedStates`.
  */
  targetState: @s.matches(stringOptionSchema) option<string>,
  /**
  Whether this command variant is exposed in the generated API (a non-`@noApi`
  variant of a non-`@noApi` command). Dev tooling badges API-exposed commands in
  the event graph. js_nullable (T | null) so it stays JSON-safe inside the
  persisted/lifecycle payloads; absent on defs written before this field existed
  (read as None) — those stores must be reset. See [[sury-optional-field-absent-vs-null]].
  */
  apiExposed: @s.matches(boolOptionSchema) option<bool>,
  /**
  Access keys a caller must hold — any one of them — to be *offered* this command,
  derived from the authorization rule the server already enforces. `None` (or `[]`)
  means the rule asks for nothing a client can check.

  A hint, never a boundary: the rule in the resolver is what refuses a call, and a
  caller who edits this list gains nothing. It exists so a client stops advertising
  what the server would refuse — an offered command that always fails is a worse
  answer than no command at all. Derived rather than authored, so it cannot drift
  from the rule it describes. js_nullable, so defs written before this field
  existed decode as None.
  */
  requiredAccess: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /**
  Name of the command field the server stamps with the caller's own identity, when
  the command declares one (`@owner`). A client should omit it from a generated
  form for a caller who is not elevated: whatever it collects there is discarded
  and replaced, so offering the field asks a question whose answer is ignored.

  Derived from the annotation, never authored, so it cannot disagree with what the
  write path actually does. js_nullable for the same JSON-safety reason as
  `requiredAccess`.

  ⚠️ A client cannot decide the *elevated* half from this alone — the manifest
  states which field carries the owner, and the caller's own identity says whether
  they are exempt. Both are needed, and neither is derivable from the other.
  */
  ownerField: @s.matches(stringOptionSchema) option<string>,
}

@schema
type queryableDef = {
  name: string,
  queryField: string,
  schema: string,
  consumedEventTypes: array<string>,
  linkedWriteSide: array<string>,
  /**
  The field on this entity that carries the human-readable label.
  When the entity's state schema declares one or more `@displayName` annotations,
  this resolves to `"displayName"` (the projected column). Otherwise it falls back
  to the first non-`id` string property, or `"id"` as a last resort.
  */
  labelField: string,
  /**
  Fields appropriate for label-oriented text search.
  Mirrors `labelField` when the entity uses the fallback or single-field label.
  For composite `@displayName` annotations, lists the *raw* underlying source
  fields (so clients with substring indexes can target them directly).
  */
  searchableFields: array<string>,
  /**
  Which rung of the `labelField` ladder produced it, so a consumer with a name
  rule of its own can tell a declaration from a guess before ranking the two:

  - `"annotation"` — a `@displayName` spec. The author said which field names the
    record; nothing a client infers locally outranks it.
  - `"convention"` — a field literally named `name`/`title`/`label`/`displayName`.
    A guess, and the one guess a client can independently arrive at.
  - `"position"` — the first candidate in declaration order. A guess, and a fact
    only this side knows; a client's own conventional-name rule is the better
    answer where the two differ.
  - `"fallback"` — no candidate at all, so `labelField` is `"id"`. The state
    saying it has no human-readable field.

  `None` means not stated — defs persisted before this field existed, and
  hand-rolled defs that decline to say. Distinct from `Some("fallback")`, which
  is this side stating that it looked. js_nullable for the same JSON-safety
  reason as `lifecycleField`.
  */
  labelFieldSource: @s.matches(stringOptionSchema) option<string>,
  /**
  Name of the state field whose value identifies the row's lifecycle, used by
  AutoUI together with `commandDef.allowedStates` to filter the per-row command
  menu. Resolution order (codegen): (1) field annotated `@lifecycle`; (2) a field
  literally named `"lifecycle"` whose shape is an enum; (3) `None`. Spec authors
  that hand-roll a `queryableDef` set this explicitly.
  */
  lifecycleField: @s.matches(stringOptionSchema) option<string>,
  /**
  Name of the state field that ties a row to the principal owning it (`@owner`),
  when the view declares one. Two consequences for a client: reads of this view
  are narrowed server-side to a non-elevated caller's own rows, and the column is
  constant for such a caller and so carries no information in a list.

  Derived from the annotation. As on `commandDef.ownerField`, this states which
  field carries the owner and not whether the current caller is exempt — that is
  the caller's own identity to answer.
  */
  ownerField: @s.matches(stringOptionSchema) option<string>,
  /**
  Name of the boolean state field that withdraws a row from ordinary reads
  (`@retired`), when the view declares one. Reads of this view exclude rows whose
  flag is true for callers outside `OwnerScope.elevatedGroups`, on the list door
  and the single-entity door alike; an exempt caller reaches them by asking for
  them.

  Derived from the annotation and from nothing else — deliberately no fallback to
  a conventionally-named boolean, unlike `lifecycleField`. A field named `archived`
  that nobody annotated must not start hiding rows the day this ships, and the
  cost of guessing wrong here is data disappearing rather than a menu filtering
  oddly.

  The label the flag reads as is not here. It travels on the state schema, which
  every consumer of this def already holds, and a second copy is a second thing
  to keep in step.
  */
  retiredField: @s.matches(stringOptionSchema) option<string>,
  /**
  The states a row is retired *in*, when the view declares the state form of
  `@retired` — `Some(["Archived", "Discontinued"])` beside
  `retiredField: Some("shelfStatus")`. `None` is the boolean form, where the
  excluded value is always `true` and naming it would be a field that can only
  hold one thing.

  A set: a lifecycle may be withdrawn by more than one state, which exclude
  identically and differ only in the way back. Retired iff the field's value is in
  it, and one member is the ordinary case rather than a special one.

  Published beside the field rather than left for a consumer to re-derive from the
  state schema: a client holding this def holds the whole predicate, and two places
  deriving one comparison is how they come to disagree about it.

  The state form is also what lets `@allowedStates` answer command applicability
  when retired, with no annotation beyond the two — retirement expressed in the
  vocabulary a command's stance is already written in.
  */
  retiredValues: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /**
  Component visibility hint (`@@reventless.visibility`). `Some("Internal")` marks a
  ReadModel / StateViewSlice that the deployed AutoUI hides from its menu, drill-down
  pages, web event graph and cross-plugin edges. `None` (absent) means Public. Internal
  components are still CARRIED in `pluginStructure` (tagged here) so developer tools — the
  `reventless-gwt` / VSCode domain graph and dead-code analysis — can see them, per
  Visibility.res. Optional for back-compat: definitions persisted before this field
  existed decode as `None` (Public).
  */
  visibility: @s.matches(stringOptionSchema) option<string>,
  /**
  Intra-plugin grouping band (the "chapter") this component belongs to, captured at
  build time from its source folder by the plugin generator: the first path segment
  under the plugin's `src/` that is not a recognised kind-folder
  (`src/<Chapter>/…/<Component>.res` → `Some("<Chapter>")`; a component directly under a
  kind-folder → `None`). Lets a consumer that renders the event graph from the
  *deployed* plugin structure group components into chapter sub-containers identically
  to the authoring tooling, with no workspace/disk access — the renderer already
  supports the bands (`DomainGraphD2 ~chapters`); only this datum was missing on the
  deployed side. `None` (absent) renders flat. js_nullable (T | null) keeps it JSON-safe
  inside the lifecycle Message union; always written (None → null), so defs persisted
  before this field existed must be reset/re-emitted. See [[deployed-chapter-grouping]].
  */
  chapter: @s.matches(stringOptionSchema) option<string>,
  /**
  The singular counterpart of `queryField`: the generated single-entity query
  (`Plugin_Order(id: ID!)` beside the list field `Plugin_Orders`), and — because
  `Api_Naming` returns the same string for both — the prefix of the queryable's
  generated input types (`Plugin_OrderFilter`, `Plugin_OrderOrderBy`). One field
  rather than two, so the two uses cannot drift apart.

  Published because it is not derivable from `queryField` without re-implementing
  `Api_Naming.singularize`: a consumer that strips a trailing `s` turns
  `Plugin_Categories` into `Plugin_Categorie`, a name the schema does not serve,
  and fails at query time against that one view. Sourced from the naming module
  itself, never re-derived.

  `None` means not stated — defs persisted before this field existed, and
  hand-rolled defs that decline to say; a consumer falls back to its own
  derivation there. js_nullable for the same JSON-safety reason as `lifecycleField`.
  */
  singleQueryField: @s.matches(stringOptionSchema) option<string>,
  /**
  The state field that identifies a row — the queryable's own key, as opposed to
  a reference to some other entity. `Products` carries `productId` and
  `categoryId`; this says which of the two the row is about.

  `None` means unresolved: a state with several `*Id` fields and no name match,
  or with none at all. Such a component gets no key-derived filter or sort until
  its spec declares `@id`. Also `None` on defs persisted before this field
  existed. js_nullable for the same JSON-safety reason as `lifecycleField`.
  */
  idField: @s.matches(stringOptionSchema) option<string>,
  /**
  Which rung produced `idField`, so a consumer can tell a declaration from a
  guess — the same reason `labelFieldSource` exists:

  - `"annotation"` — the state declares `@id`. The author said which field keys
    the row; nothing inferred outranks it.
  - `"convention"` — a field named `<singular component name>Id` exists
    (`Products` → `productId`). A guess, and the one guess a client can make for
    itself.
  - `"sole"` — the state has exactly one `*Id` field, so there is nothing else
    the key could be (`AvailableProducts` → `productId`). A guess, and one that
    needs the state's full field list to make.

  `None` whenever `idField` is `None`, and on defs that predate the field.
  */
  idFieldSource: @s.matches(stringOptionSchema) option<string>,
  /**
  Access keys a caller must hold — any one of them — to be *offered* this view,
  derived from the component's module-level authorization rule. Same terms as
  `commandDef.requiredAccess`: a hint that keeps a client from advertising a
  surface the server would refuse, never the refusal itself.

  Worth stating for reads in particular: a denied query does not error, it comes
  back empty, so a client that offers a view it may not read renders a confident
  blank table rather than a visible failure.
  */
  requiredAccess: @s.matches(stringArrayOptionSchema) option<array<string>>,
}

/**
One emitted event of a write side, with its field schema. Mirrors `commandDef`
but for the past-tense facts a write side produces: `name` is the event variant
name (e.g. `OrderPlaced`), `schema` is the JSON Schema of that variant's payload
(same serialization as `commandDef.schema`: `SuryToJsonSchema.deriveObjectSchema`,
so field-level `x-reventless-*` extensions are carried and the variant's `TAG`
discriminator is not — the constructor name is already `name`), `references` its
cross-entity field links.
Carried so developer tools (the `reventless-dev` / VSCode domain graph) can show
event field rows — AutoUI ignores it. */
@schema
type eventDef = {
  name: string,
  schema: string,
  references: array<fieldReference>,
}

/**
One declared error of a write side, with its field schema. Same shape and same
derivation as `eventDef` — a refusal is a variant of `Spec.errorSchema` exactly as
an emitted fact is a variant of `Spec.eventSchema`, so a consumer reading an
error's payload walks it with the code path it already uses for an event. `name`
is the variant name (e.g. `CategoryNotFound`) — the same string the runtime puts
on `errorCode` when a decision is rejected (see `CommandTopic_Helpers`), so a
caller can match what it reads here against what it receives. Payload-less
variants (the common case for errors) carry an empty `schema` object and no
references.
*/
@schema
type errorDef = {
  name: string,
  schema: string,
  references: array<fieldReference>,
}

@schema
type writableDef = {
  name: string,
  commands: array<commandDef>,
  producedEventTypes: array<string>,
  consumedEventTypes: array<string>,
  linkedViews: array<string>,
  consistencyRead: @s.matches(stringOptionSchema) option<string>,
  /** Emitted-event field schemas. Required like the other write-side arrays; `[]`
  when there are none. */
  events: array<eventDef>,
  /** Declared-error field schemas — what this component can refuse a command with.
  Required, on the same reasoning as `events`: the persisted copy is never decoded
  through this schema (the event log carries it as an offload reference, and the
  serving path reads it as raw JSON), so `[]` honestly means "declares no errors"
  rather than "an older deploy could not say".

  Being required does NOT make it safe to add such a field without a read-path
  shim. A structure is re-derived on every build, but it is only RE-REGISTERED
  when a plugin re-runs the connect handshake — which a plugin whose version never
  changes may not do for a long time. Until then the serving path reads a
  persisted structure that has no key for the new field, and against a `[T!]!` SDL
  field that null propagates to the root and answers the whole query with `data:
  null`. Both admin resolvers therefore heal absent required lists to `[]` on
  read; a new one has to be added to that list too. */
  errors: array<errorDef>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type automationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  producedCommandTypes: array<string>,
  targetName: string,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type outboundTranslationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  inboundCommandTypes: array<string>,
  targetName: @s.matches(stringOptionSchema) option<string>,
  // Foreign system this slice publishes to — drives the external box (Event Graph).
  externalSystem: @s.matches(stringOptionSchema) option<string>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type inboundTranslationSliceDef = {
  name: string,
  commandTypes: array<string>,
  targetName: string,
  // Foreign system this slice receives from — drives the external box (Event Graph).
  externalSystem: @s.matches(stringOptionSchema) option<string>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type extensionDef = {
  name: string,
  delegateNames: array<string>,
  eventTypes: array<string>,
  commandTypes: array<string>,
}

/**
Describes an extension point owned by a plugin, from the *producer* side.

`sourceEventTypes` are the owner-plugin internal events (the `Delegate`'s events)
that feed this extension point's published protocol — plugin-qualified to match
`writableDef.producedEventTypes`, so the event graph can link a producing
write-side to the extension point it ultimately feeds. `delegateNames` are the
connected targets (one per `ExtensionPointMapping`).

`commandTypes` are the EP's *inbound* command protocol (the variants of its
`command` type). It is empty (None, read as []) when the EP declares
`command = unit` — a notification-only, events-out boundary that accepts nothing
inward. The event graph uses this to decide whether the EP routes any command (an
empty list means no `routesTo` edge: there is nothing for the EP to route).

Optional (None for a `command = unit` EP). Uses the `js_nullable` pattern (T | null).
A sury field cannot be BOTH absent-tolerant on decode AND JSON-encodable (proven:
S.option = `T|undefined`, nullableAsOption = `T|undefined|null` both decode an absent
key but fail jsonableValidation; js_nullable = `T|null` is the only JSON-safe form but
rejects an absent key). This def is nested in the JSON-encoded lifecycle Message union
(Connect/Heartbeat), so jsonability wins → js_nullable. It always writes the field
(None → null), so it is present-required on decode; a plugin definition persisted
before this field existed must be reset/re-emitted. Read with `->Option.getOr([])`.
*/
@schema
type extensionPointDef = {
  name: string,
  delegateNames: array<string>,
  sourceEventTypes: array<string>,
  commandTypes: @s.matches(stringArrayOptionSchema) option<array<string>>,
}

// js_nullable creates `array | null` (not `| undefined`), which passes sury's
// jsonableValidation inside the pluginStructure union variant payload.
let extensionPointDefArrayOptionSchema = _jsNullable(S.array(extensionPointDefSchema), ())

/**
One field's store requirement, with its provenance.

`store` is the same qualified `{plugin}.{store}` string `requiredStores`
carries; `component` and `field` name the declaration site. The site matters
because a requirement only ever changes by editing a field — when a rename
removes a store from the manifest, the diff has to say which field caused it.

`annotation` is the store exactly as the field spells it — bare for a store
the declaring plugin owns, qualified for a foreign one. It is recorded rather
than reconstructed: only here is the owning plugin unambiguous, so anything
downstream would have to infer it by comparing a registered plugin name with
whatever name a deploy manifest happened to use, and those were never required
to match.

Optional for the same reason `CapabilityManifest.provenance` and
`PlatformCodegen.provenance` — the two places this value travels onward to —
already declare it optional: an event stored before the field existed cannot
say what the source said, and a reader that cannot say omits the claim rather
than inventing one. Every definition emitted now carries it.

That is not a stylistic preference. It was first added here as a required
`string` while events written without it were already stored, and since the
lifecycle aggregate replays its own log before every decision, those events
stopped decoding and the plugin's registration froze for two days. `None` is
also the honest value: `""` would assert the author wrote an empty annotation.
See the schema-evolution note on `pluginStructure` below.
*/
@schema
type requiredStoreDeclaration = {
  store: string,
  component: string,
  field: string,
  annotation: @s.matches(stringOptionSchema) option<string>,
}

let requiredStoreDeclarationArrayOptionSchema = _jsNullable(
  S.array(requiredStoreDeclarationSchema),
  (),
)

/**
Adding a field here? It has to be a shape a stale event can be healed into.

Everything reachable from `pluginDefinition` is persisted in the Plugin lifecycle
aggregate's event log, and that aggregate replays its own log before every
decision. Events already written do not have your new field, so if decoding one
of them throws, the aggregate cannot process ANY command for that plugin — it
stops answering the deploy handshake and its registration silently freezes at
whatever version connected last.

`Message.parseJsonTolerant` heals a stale event on read, but only for shapes it
can supply a value for: a `T | null` union (→ `None`), an array (→ `[]`), a
mandatory enum (→ first variant), a nested object (→ recursively filled), and a
scalar (→ `""` / `0` / `false`, logged as a warning because it is a fabricated
value, not a derived one).

So: **prefer `js_nullable` for anything genuinely optional**, and expect a scalar
addition to show up as a warning in the logs of every deployment that still holds
older events. A field that can be absent should say so in its type rather than
lean on the healer.

The regression suite for this is `PluginLifecycleCorpusTest` in reventless-core,
which decodes frozen payloads captured off a deployed log. If it goes red naming
your field, re-shape the field — do not re-cut the fixtures. Background:
`docs/analysis/plugin-definition-schema-evolution-wedge.md`.
*/
@schema
type pluginStructure = {
  readModels: array<queryableDef>,
  stateViewSlices: array<queryableDef>,
  stateChangeSlices: array<writableDef>,
  aggregates: array<writableDef>,
  automationSlices: array<automationSliceDef>,
  outboundTranslationSlices: array<outboundTranslationSliceDef>,
  inboundTranslationSlices: array<inboundTranslationSliceDef>,
  extensions: array<extensionDef>,
  // Extension points owned by this plugin (producer side). Optional so plugin
  // definitions persisted before this field existed still decode (absent → None,
  // read as []). js_nullable keeps it JSON-safe inside union variant payloads.
  extensionPoints: @s.matches(extensionPointDefArrayOptionSchema)
  option<array<extensionPointDef>>,
  /**
   The object stores this plugin's fields declare they need, deduplicated and
   fully qualified as `{plugin}.{store}`.

   A field typed as a storage ref states a *requirement*: the deployment needs
   that store to exist. Collecting the requirement here is what lets it be read
   without re-walking every component's schema — the same reason
   `producedEventTypes` is carried rather than recomputed.

   Qualified even for the common same-plugin case, so one entry has one shape
   and the string is directly the store's identity. Optional and js_nullable for
   the same reason as `extensionPoints`: definitions persisted before this field
   existed still decode (absent → None, read as []).
   */
  requiredStores: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /**
   Provenance for `requiredStores`: one entry per declaring `(component, field)`
   site, with `store` matching the qualified key above. `requiredStores` is
   derived from this list, so the two cannot disagree. Optional and js_nullable
   for the same reason as `extensionPoints`.
   */
  requiredStoreDeclarations: @s.matches(requiredStoreDeclarationArrayOptionSchema)
  option<array<requiredStoreDeclaration>>,
}

let pluginStructureOffloadSchema = Offload.optionSchema(~store="pluginStructures", pluginStructureSchema)

/**
The self-description of a deployed plugin, persisted in the plugin's event store.

Used by the gateway to discover extension points, extensions, and protocol versions.
The `eventCollector` field is mutable so it can be set after the heartbeat lambda
registers its own ARN.
*/
@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  // Protocol version declarations for each extension point this plugin connects to.
  // Use [] when the plugin does not need version negotiation.
  extensionProtocols: array<extensionProtocol>,
  // GraphQL schema fragment contributed by this plugin (optional, set at build time).
  // Offloadable: a large SDL fragment is content-addressed to the pluginApiFragments
  // store by the client and carried by reference; a small one stays Inline. optionSchema
  // wraps the untagged codec in js_nullable (T | null, not T | undefined | null) so it
  // passes jsonableValidation inside the lifecycle Message union, and marks the store.
  apiSchemaFragment: @s.matches(apiSchemaFragmentOffloadSchema) option<Offload.payload<apiSchemaFragment>>,
  // API target for schema routing in split-API mode.
  // None/"Domain" → fragment goes to the DomainApi (default).
  // Some("Platform") → fragment goes to the PlatformApi; excluded from DomainApi runtime schema.
  // Uses @s.matches(stringOptionSchema) — js_nullable creates string | null (not string | undefined),
  // which passes sury's jsonableValidation inside union variant payloads.
  apiTarget: @s.matches(stringOptionSchema) option<string>,
  // Component graph metadata — populated by makePluginDefinition; absent for older protocol versions.
  // Offloadable: the large structure is content-addressed to the pluginStructures store by
  // the client and carried by reference; a small one stays Inline (see apiSchemaFragment).
  structure: @s.matches(pluginStructureOffloadSchema) option<Offload.payload<pluginStructure>>,
  // DCB EventLog definition for plugins that bundle a DcbEventLog component.
  // Carries the EventTopic ARN so the admin can provision cross-plugin SNS
  // subscriptions from this plugin's DCB topic → peer EventCollectors.
  // None for plugins without a DCB EventLog.
  dcbEventLog: @s.matches(dcbEventLogOptionSchema) option<dcbEventLogDefinition>,
  // Business role of this plugin. Mandatory: `Domain` is the default kind, resolved once
  // at the deploy-metadata → definition boundary (Plugin_Builder). PlatformInfrastructure
  // plugins are segregated out of the admin Plugins list. Payload-less variant → serialises
  // as a bare JSON string, so it is JSON-safe inside the lifecycle Message union without js_nullable.
  kind: pluginKind,
}

