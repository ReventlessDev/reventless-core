/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

/** A plugin's business role, used by the admin Plugins view to segregate
    infrastructure from domain plugins. Absent is read as `Domain`. */
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
  /** Peer `dcbEventLogDefinition.name`s this extension consumes (`${peer}DcbEventLog`),
      which the admin turns into cross-plugin SNS subscriptions. */
  dcbSources: array<string>,
}

/** A DCB EventLog exposed by a plugin, so the admin can subscribe peer plugins
    that reference it by name. */
@schema
type dcbEventLogDefinition = {
  /** Service name carried in event meta — convention: `${plugin.name}DcbEventLog`. */
  name: string,
  /** SNS topic ARN for the DCB EventLog's EventTopic. */
  eventTopicArn: string,
}

/** Protocol versions for one extension point connection, carried in the
    `ConnectPlugin` handshake. `[]` when negotiation is not needed. */
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

/** Which API a plugin's GraphQL fields are stitched into. Serializes as the bare
    string "Domain" / "Platform". */
@schema
type apiTarget = Domain | Platform

// js_nullable (T | null) is the only optional that passes jsonableValidation inside
// union variant payloads; nullableAsOption adds `undefined` and fails it.
let apiSchemaFragmentOffloadSchema = Offload.optionSchema(~store="pluginApiFragments", apiSchemaFragmentSchema)
let dcbEventLogOptionSchema = dcbEventLogDefinitionSchema->S.nullAsOption
let stringOptionSchema = S.string->S.nullAsOption
let stringArrayOptionSchema = S.array(S.string)->S.nullAsOption
let boolOptionSchema = S.bool->S.nullAsOption

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

let uiFragmentManifestOptionSchema = uiFragmentManifestSchema->S.nullAsOption

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
  /** The `@transition` *from* set — lifecycle states this command is meaningful in.
      `None` means always available; `Some([])` means never show. */
  allowedStates: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /** The `@transition` *to* state this command's handler writes. `None` with a
      from-set present means the command does not move the row. */
  targetState: @s.matches(stringOptionSchema) option<string>,
  /** Whether the variant is exposed in the generated API (non-`@noApi`). */
  apiExposed: @s.matches(boolOptionSchema) option<bool>,
  /** Access keys — any one of them — a caller needs to be *offered* this command.
      A hint derived from the server's rule, never the refusal itself. */
  requiredAccess: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /** The `@owner` command field the server stamps with the caller's identity; a
      client omits it from a form, since whatever it collects is discarded. */
  ownerField: @s.matches(stringOptionSchema) option<string>,
}

@schema
type queryableDef = {
  name: string,
  queryField: string,
  schema: string,
  consumedEventTypes: array<string>,
  linkedWriteSide: array<string>,
  /** The field carrying the human-readable label: `"displayName"` when the state
      declares `@displayName`, else the first non-`id` string, else `"id"`. */
  labelField: string,
  /** Fields for label-oriented text search — the *raw* source fields behind a
      composite `@displayName`, else `labelField`. */
  searchableFields: array<string>,
  /** Which rung produced `labelField`, so a consumer can rank it against its own
      rule: `"annotation"` | `"convention"` | `"position"` | `"fallback"`. */
  labelFieldSource: @s.matches(stringOptionSchema) option<string>,
  /** The state field holding the row's lifecycle, paired with
      `commandDef.allowedStates`. From `@lifecycle`, else an enum named `lifecycle`. */
  lifecycleField: @s.matches(stringOptionSchema) option<string>,
  /** The `@owner` state field. Reads of this view are narrowed server-side to a
      non-elevated caller's own rows. */
  ownerField: @s.matches(stringOptionSchema) option<string>,
  /** The `@retired` state field withdrawing a row from ordinary reads. From the
      annotation only — no fallback by name, since guessing hides data. */
  retiredField: @s.matches(stringOptionSchema) option<string>,
  /** The states a row is retired *in* (state form of `@retired`); `None` is the
      boolean form, where the excluded value is always `true`. */
  retiredValues: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /** Whether the view publishes the by-ids reference door that names a retired row
      to any caller holding a pointer (`@namedWhenRetired`). Never true without
      `retiredField`. */
  namedWhenRetired: @s.matches(boolOptionSchema) option<bool>,
  /** `@@reventless.visibility`. `Some("Internal")` hides the component from AutoUI;
      it is still carried here for developer tooling. `None` means Public. */
  visibility: @s.matches(stringOptionSchema) option<string>,
  /** Intra-plugin grouping band, the first non-kind path segment under `src/`.
      `None` renders flat. */
  chapter: @s.matches(stringOptionSchema) option<string>,
  /** The singular counterpart of `queryField` (`Plugin_Order`), also the prefix of
      the generated input types. Not derivable without `Api_Naming.singularize`. */
  singleQueryField: @s.matches(stringOptionSchema) option<string>,
  /** The state field identifying a row, as opposed to a reference to another entity.
      `None` means unresolved — no key-derived filter or sort until `@id` is declared. */
  idField: @s.matches(stringOptionSchema) option<string>,
  /** Which rung produced `idField`, as `labelFieldSource` does: `"annotation"` |
      `"convention"` | `"sole"`. */
  idFieldSource: @s.matches(stringOptionSchema) option<string>,
  /** Access keys — any one of them — a caller needs to be *offered* this view. A
      denied read comes back empty rather than erroring, hence the hint. */
  requiredAccess: @s.matches(stringArrayOptionSchema) option<array<string>>,
}

/** One emitted event of a write side. `name` is the variant name, `schema` its
    payload's JSON Schema (no `TAG` — the constructor name is already `name`). */
@schema
type eventDef = {
  name: string,
  schema: string,
  references: array<fieldReference>,
}

/** One declared error of a write side, derived exactly as `eventDef`. `name` is the
    string the runtime puts on `errorCode`; payload-less variants carry `{}`. */
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
  /** Emitted-event field schemas; `[]` when there are none. */
  events: array<eventDef>,
  /** Declared-error field schemas. Required, but a persisted structure predating a
      required list still lacks the key — both admin resolvers heal absent ones to
      `[]` on read, and a new one must be added there too. */
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

/** A published event of an extension point and the internal events producing it.
    `name` is EP-qualified, `fromEventTypes` plugin-qualified; `[]` means published
    from a path the declaration cannot name. */
@schema
type publishedEventDef = {
  name: string,
  fromEventTypes: array<string>,
}

let publishedEventDefArrayOptionSchema = S.array(publishedEventDefSchema)->S.nullAsOption

/** The command direction's producer half: a command an extension point takes and
    the delegate commands it routes to. `name` is EP-qualified, `toCommandTypes`
    plugin-qualified. */
@schema
type acceptedCommandDef = {
  name: string,
  toCommandTypes: array<string>,
}

let acceptedCommandDefArrayOptionSchema = S.array(acceptedCommandDefSchema)->S.nullAsOption

/** The subscriber's half: a published event and the commands it routes to. A
    delegate command is plugin-qualified, one sent back to the EP is EP-qualified. */
@schema
type handledEventDef = {
  name: string,
  toCommandTypes: array<string>,
}

let handledEventDefArrayOptionSchema = S.array(handledEventDefSchema)->S.nullAsOption

/** The command direction's subscriber half: a command sent back to the port and
    the internal events producing it. `name` is EP-qualified, `fromEventTypes`
    plugin-qualified. */
@schema
type issuedCommandDef = {
  name: string,
  fromEventTypes: array<string>,
}

let issuedCommandDefArrayOptionSchema = S.array(issuedCommandDefSchema)->S.nullAsOption

@schema
type extensionDef = {
  name: string,
  delegateNames: array<string>,
  eventTypes: array<string>,
  commandTypes: array<string>,
  /** Which published event routes to which commands. js_nullable like
      `extensionPointDef.commandTypes`; re-emit definitions persisted before it. */
  handledEvents: @s.matches(handledEventDefArrayOptionSchema) option<array<handledEventDef>>,
  /** Which internal event sends which command back to the port. `None` means a
      definition persisted before the field, NOT an extension that issues nothing —
      a reader joining the two halves must keep them apart. */
  issuedCommands: @s.matches(issuedCommandDefArrayOptionSchema) option<array<issuedCommandDef>>,
}

/**
An extension point owned by a plugin, from the producer side.

`sourceEventTypes` are the `Delegate`'s events feeding the published protocol,
plugin-qualified to match `writableDef.producedEventTypes`. `commandTypes` is the
EP's inbound protocol — None (read as []) for a `command = unit` EP, which routes
nothing. js_nullable is the only JSON-safe optional here (this def is nested in the
lifecycle Message union); definitions persisted before a field must be re-emitted.
*/
@schema
type extensionPointDef = {
  name: string,
  delegateNames: array<string>,
  sourceEventTypes: array<string>,
  commandTypes: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /** Which internal event becomes which published event. */
  publishedEvents: @s.matches(publishedEventDefArrayOptionSchema)
  option<array<publishedEventDef>>,
  /** Which arriving command becomes which delegate command. `None` means a
      definition persisted before the field, NOT a port that accepts nothing. */
  acceptedCommands: @s.matches(acceptedCommandDefArrayOptionSchema)
  option<array<acceptedCommandDef>>,
}

// js_nullable creates `array | null` (not `| undefined`), which passes sury's
// jsonableValidation inside the pluginStructure union variant payload.
let extensionPointDefArrayOptionSchema = S.array(extensionPointDefSchema)->S.nullAsOption

/**
One field's store requirement, with its provenance.

`store` is the qualified `{plugin}.{store}` string `requiredStores` carries;
`component` and `field` name the declaration site, so a diff can say which field
added or removed a store. `annotation` is the store as the field spells it —
recorded, not reconstructed, since only here is the owning plugin unambiguous.
Optional because an event stored before it cannot say (`""` would claim it did).
*/
@schema
type requiredStoreDeclaration = {
  store: string,
  component: string,
  field: string,
  annotation: @s.matches(stringOptionSchema) option<string>,
}

let requiredStoreDeclarationArrayOptionSchema =
  S.array(requiredStoreDeclarationSchema)->S.nullAsOption

/**
One component's capability requirement, with its provenance.

`capability` is `CapabilityNeed.toString` — a string rather than an enum so a
plugin built against a newer framework still decodes here; `component` names the
slice that declared it, so a diff can say which component added or removed the
need. Unlike a store there is no field: what a `translate` reaches for is not
expressible as an annotation on one, which is why the need is declared.
*/
@schema
type requiredCapabilityDeclaration = {capability: string, component: string}

let requiredCapabilityDeclarationArrayOptionSchema =
  S.array(requiredCapabilityDeclarationSchema)->S.nullAsOption

/**
One graft's provenance: which trait, at which version, on which component.

Strings rather than the `Trait.t` variant for `posture`, on the same rule the
capability above follows — a plugin built against a newer framework, naming a
posture this one has never heard of, still decodes here rather than failing the
whole structure.

`component` is not declared by the trait or by the host: the structure fills it in
while it walks the components, because it is the only party that knows which one
carried the declaration. Nothing in this record is a string a developer typed.

It records ORIGIN, not behaviour — a grafted file is the host's to edit
afterwards. What answers "does it still behave like the trait" is the trait's own
conformance suite, which runs in the consumer's build and is not this field.
*/
@schema
type traitDeclaration = {
  trait: string,
  version: string,
  posture: string,
  component: string,
}

let traitDeclarationArrayOptionSchema = S.array(traitDeclarationSchema)->S.nullAsOption

/**
Adding a field here? It must be a shape a stale event can be healed into — the
lifecycle aggregate replays its own log before every decision, so one event that
fails to decode freezes that plugin's registration. `Message.parseJsonTolerant`
heals `T | null`, arrays, enums and nested objects; a bare scalar is fabricated
and warned about. Prefer `js_nullable`. Regression suite:
`PluginLifecycleCorpusTest` — if it goes red, re-shape the field, not the fixtures.
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
  // Extension points owned by this plugin (producer side). Optional so older
  // definitions still decode (absent → None, read as []).
  extensionPoints: @s.matches(extensionPointDefArrayOptionSchema)
  option<array<extensionPointDef>>,
  /** The object stores this plugin's fields declare they need, deduplicated and
      qualified as `{plugin}.{store}` even for the same-plugin case. */
  requiredStores: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /** Provenance for `requiredStores`: one entry per declaring `(component, field)`.
      `requiredStores` is derived from it, so the two cannot disagree. */
  requiredStoreDeclarations: @s.matches(requiredStoreDeclarationArrayOptionSchema)
  option<array<requiredStoreDeclaration>>,
  /** The platform capabilities this plugin's components declare they need, one
      entry per declaring component. Object stores are not here — a store need is
      a field's, and travels as `requiredStores`. Absent → None, read as []. */
  requiredCapabilities: @s.matches(requiredCapabilityDeclarationArrayOptionSchema)
  option<array<requiredCapabilityDeclaration>>,
  /** The domain traits grafted into this plugin, one entry per declaring
      component. Absent → None, read as []. The only signal a graft leaves that
      survives into a deployed plugin — every other one (the dependency, the
      variant spread, the rules alias, the conformance binding) is source-side.
      A claim about origin, never about behaviour: see `Trait`. */
  traitDeclarations: @s.matches(traitDeclarationArrayOptionSchema)
  option<array<traitDeclaration>>,
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
  // [] when the plugin does not need version negotiation.
  extensionProtocols: array<extensionProtocol>,
  // Offloadable: a large SDL fragment is content-addressed to the pluginApiFragments
  // store and carried by reference; a small one stays Inline.
  apiSchemaFragment: @s.matches(apiSchemaFragmentOffloadSchema) option<Offload.payload<apiSchemaFragment>>,
  // Schema routing in split-API mode: None/"Domain" → DomainApi, Some("Platform") →
  // PlatformApi (and excluded from the DomainApi runtime schema).
  apiTarget: @s.matches(stringOptionSchema) option<string>,
  // Component graph metadata, offloadable like apiSchemaFragment. Absent for older
  // protocol versions.
  structure: @s.matches(pluginStructureOffloadSchema) option<Offload.payload<pluginStructure>>,
  // EventTopic ARN of a bundled DcbEventLog, so the admin can subscribe peer
  // EventCollectors to it. None for plugins without one.
  dcbEventLog: @s.matches(dcbEventLogOptionSchema) option<dcbEventLogDefinition>,
  // Mandatory; `Domain` is resolved as the default in Plugin_Builder. Payload-less
  // variant → a bare JSON string, so JSON-safe without js_nullable.
  kind: pluginKind,
}

