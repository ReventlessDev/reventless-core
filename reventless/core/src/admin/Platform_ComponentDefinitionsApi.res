// SDL types and JSON encoder for the Platform_ComponentDefinitions GraphQL query.
// Shared between the in-memory adapter (which resolves from an in-process store)
// and the AWS adapter (which resolves from the Plugin read model). Keeping both
// adapters byte-identical guarantees a single client query string works against
// both.
//
// The component-level types below are shared with `Platform_PluginStructuresApi`,
// which serves the same components unfiltered to developer tooling. They are
// declared here because this is where their encoders live; the two queries differ
// in WHICH components they return and what the entry carries around them, never in
// how one component is shaped.

open Reventless.Plugin

// Component-level SDL. Every field a leaf encoder below emits is declared here:
// a field the resolver returns but the SDL omits is unreachable (GraphQL rejects
// selecting it), which is how `chapter` and `externalSystem` stayed invisible to
// consumers long after they were being encoded.
let sdlTypes: array<string> = [
  `type Platform_FieldReference {\n  fieldName: String!\n  entity: String!\n  plugin: String\n}`,
  `type Platform_CommandDef {\n  name: String!\n  schema: String!\n  level: String!\n  aggregateIdField: String\n  mutationField: String!\n  references: [Platform_FieldReference!]!\n  allowedStates: [String!]\n  targetState: String\n  apiExposed: Boolean\n}`,
  `type Platform_EventDef {\n  name: String!\n  schema: String!\n  references: [Platform_FieldReference!]!\n}`,
  // Same fields as Platform_EventDef, kept a distinct type because a refusal is not
  // a fact: a caller selecting `errors` is asking what a command can be rejected
  // with, and the two lists must stay independently evolvable.
  `type Platform_ErrorDef {\n  name: String!\n  schema: String!\n  references: [Platform_FieldReference!]!\n}`,
  `type Platform_WriteSideDef {\n  name: String!\n  commands: [Platform_CommandDef!]!\n  linkedViews: [String!]!\n  consistencyRead: String\n  producedEventTypes: [String!]!\n  consumedEventTypes: [String!]!\n  events: [Platform_EventDef!]!\n  errors: [Platform_ErrorDef!]!\n  chapter: String\n}`,
  `type Platform_ReadSideDef {\n  name: String!\n  queryField: String!\n  schema: String!\n  consumedEventTypes: [String!]!\n  linkedWriteSide: [String!]!\n  labelField: String!\n  searchableFields: [String!]!\n  labelFieldSource: String\n  statusField: String\n  visibility: String\n  chapter: String\n}`,
  `type Platform_AutomationSliceDef {\n  name: String!\n  consumedEventTypes: [String!]!\n  producedCommandTypes: [String!]!\n  targetName: String\n  chapter: String\n}`,
  `type Platform_OutboundTranslationSliceDef {\n  name: String!\n  consumedEventTypes: [String!]!\n  inboundCommandTypes: [String!]!\n  targetName: String\n  externalSystem: String\n  chapter: String\n}`,
  `type Platform_InboundTranslationSliceDef {\n  name: String!\n  commandTypes: [String!]!\n  targetName: String\n  externalSystem: String\n  chapter: String\n}`,
  `type Platform_ExtensionDef {\n  name: String!\n  delegateNames: [String!]!\n  eventTypes: [String!]!\n  commandTypes: [String!]!\n}`,
  `type Platform_ComponentDefinitionEntry {\n  pluginId: String!\n  readModels: [Platform_ReadSideDef!]!\n  stateViewSlices: [Platform_ReadSideDef!]!\n  stateChangeSlices: [Platform_WriteSideDef!]!\n  aggregates: [Platform_WriteSideDef!]!\n  automationSlices: [Platform_AutomationSliceDef!]!\n  outboundTranslationSlices: [Platform_OutboundTranslationSliceDef!]!\n  inboundTranslationSlices: [Platform_InboundTranslationSliceDef!]!\n  extensions: [Platform_ExtensionDef!]!\n}`,
]

let sdlQueryField: string = `  Platform_ComponentDefinitions: [Platform_ComponentDefinitionEntry!]!`

let encodeStrings = (ss: array<string>): JSON.t =>
  ss->Array.map(JSON.Encode.string)->JSON.Encode.array

let encodeFieldReference = (r: fieldReference): JSON.t =>
  Dict.fromArray([
    ("fieldName", JSON.Encode.string(r.fieldName)),
    ("entity", JSON.Encode.string(r.entity)),
    ("plugin", r.plugin->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeCommandDef = (c: commandDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(c.name)),
    ("schema", JSON.Encode.string(c.schema)),
    (
      "level",
      JSON.Encode.string(
        switch c.level {
        | Collection => "Collection"
        | Instance => "Instance"
        },
      ),
    ),
    (
      "aggregateIdField",
      c.aggregateIdField->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
    ),
    ("mutationField", JSON.Encode.string(c.mutationField)),
    ("references", c.references->Array.map(encodeFieldReference)->JSON.Encode.array),
    (
      "allowedStates",
      c.allowedStates->Option.mapOr(JSON.Encode.null, encodeStrings),
    ),
    ("targetState", c.targetState->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("apiExposed", c.apiExposed->Option.mapOr(JSON.Encode.null, JSON.Encode.bool)),
  ])->JSON.Encode.object

// Internal ReadModels / StateViewSlices are carried in pluginStructure for developer
// tooling but must stay out of the deployed AutoUI — the menu, drill-down pages and
// queryable defs are all derived from this response, so filter them here.
let isPublicQueryable = (q: queryableDef): bool => q.visibility != Some("Internal")

let encodeQueryableDef = (r: queryableDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(r.name)),
    ("queryField", JSON.Encode.string(r.queryField)),
    ("schema", JSON.Encode.string(r.schema)),
    ("consumedEventTypes", encodeStrings(r.consumedEventTypes)),
    ("linkedWriteSide", encodeStrings(r.linkedWriteSide)),
    ("labelField", JSON.Encode.string(r.labelField)),
    ("searchableFields", encodeStrings(r.searchableFields)),
    (
      "labelFieldSource",
      r.labelFieldSource->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
    ),
    ("statusField", r.statusField->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    // Carried rather than only filtered on: a tooling consumer reading the
    // unfiltered structure needs to know WHICH components are Internal, and a
    // consumer of the filtered query reads null here because nothing Internal
    // survives the filter anyway.
    ("visibility", r.visibility->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("chapter", r.chapter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeEventDef = (e: eventDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(e.name)),
    ("schema", JSON.Encode.string(e.schema)),
    ("references", e.references->Array.map(encodeFieldReference)->JSON.Encode.array),
  ])->JSON.Encode.object

let encodeErrorDef = (e: errorDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(e.name)),
    ("schema", JSON.Encode.string(e.schema)),
    ("references", e.references->Array.map(encodeFieldReference)->JSON.Encode.array),
  ])->JSON.Encode.object

let encodeWritableDef = (w: writableDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(w.name)),
    ("commands", w.commands->Array.map(encodeCommandDef)->JSON.Encode.array),
    ("linkedViews", encodeStrings(w.linkedViews)),
    (
      "consistencyRead",
      w.consistencyRead->Option.mapOr(JSON.Encode.null, JSON.Encode.string),
    ),
    ("producedEventTypes", encodeStrings(w.producedEventTypes)),
    ("consumedEventTypes", encodeStrings(w.consumedEventTypes)),
    // Phase 6.3: emitted-event field schemas (None → [] on the wire).
    ("events", w.events->Array.map(encodeEventDef)->JSON.Encode.array),
    // Declared errors — the refusals a caller has to handle. `[]` is the honest
    // answer for a component that declares none; the structure is re-derived on
    // every build, so it never stands in for "cannot say".
    ("errors", w.errors->Array.map(encodeErrorDef)->JSON.Encode.array),
    ("chapter", w.chapter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeAutomationSliceDef = (a: automationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(a.name)),
    ("consumedEventTypes", encodeStrings(a.consumedEventTypes)),
    ("producedCommandTypes", encodeStrings(a.producedCommandTypes)),
    // Routing target — the plugin this slice's commands are dispatched to. It is
    // what turns a slice into a cross-plugin edge, so a graph consumer needs it
    // from the structure rather than from the deploy-time inspector sync.
    ("targetName", JSON.Encode.string(a.targetName)),
    ("chapter", a.chapter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeOutboundTranslationSliceDef = (o: outboundTranslationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(o.name)),
    ("consumedEventTypes", encodeStrings(o.consumedEventTypes)),
    ("inboundCommandTypes", encodeStrings(o.inboundCommandTypes)),
    ("targetName", o.targetName->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    // Foreign system this slice publishes to — lets a deployed-graph consumer draw
    // the external-system boundary box without workspace access. None → null.
    ("externalSystem", o.externalSystem->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("chapter", o.chapter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeInboundTranslationSliceDef = (i: inboundTranslationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(i.name)),
    ("commandTypes", encodeStrings(i.commandTypes)),
    ("targetName", JSON.Encode.string(i.targetName)),
    // Foreign system this slice receives from — lets a deployed-graph consumer draw
    // the external-system boundary box without workspace access. None → null.
    ("externalSystem", i.externalSystem->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("chapter", i.chapter->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

let encodeExtensionDef = (e: extensionDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(e.name)),
    ("delegateNames", encodeStrings(e.delegateNames)),
    ("eventTypes", encodeStrings(e.eventTypes)),
    ("commandTypes", encodeStrings(e.commandTypes)),
  ])->JSON.Encode.object

let encodePluginStructureEntry = (~pluginId: string, def: pluginStructure): JSON.t =>
  Dict.fromArray([
    ("pluginId", JSON.Encode.string(Plugin.name(pluginId))),
    (
      "readModels",
      def.readModels->Array.filter(isPublicQueryable)->Array.map(encodeQueryableDef)->JSON.Encode.array,
    ),
    (
      "stateViewSlices",
      def.stateViewSlices
      ->Array.filter(isPublicQueryable)
      ->Array.map(encodeQueryableDef)
      ->JSON.Encode.array,
    ),
    ("stateChangeSlices", def.stateChangeSlices->Array.map(encodeWritableDef)->JSON.Encode.array),
    ("aggregates", def.aggregates->Array.map(encodeWritableDef)->JSON.Encode.array),
    (
      "automationSlices",
      def.automationSlices->Array.map(encodeAutomationSliceDef)->JSON.Encode.array,
    ),
    (
      "outboundTranslationSlices",
      def.outboundTranslationSlices
      ->Array.map(encodeOutboundTranslationSliceDef)
      ->JSON.Encode.array,
    ),
    (
      "inboundTranslationSlices",
      def.inboundTranslationSlices
      ->Array.map(encodeInboundTranslationSliceDef)
      ->JSON.Encode.array,
    ),
    ("extensions", def.extensions->Array.map(encodeExtensionDef)->JSON.Encode.array),
  ])->JSON.Encode.object
