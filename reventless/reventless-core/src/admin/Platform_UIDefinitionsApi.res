// SDL types and JSON encoder for the Platform_UIDefinitions GraphQL query.
// Shared between the in-memory adapter (which resolves from an in-process store)
// and the AWS adapter (which resolves from the Plugin read model). Keeping both
// adapters byte-identical guarantees a single client query string works against
// both.

open Reventless.Plugin

let sdlTypes: array<string> = [
  `type Platform_UIFieldReference {\n  fieldName: String!\n  entity: String!\n  plugin: String\n}`,
  `type Platform_UICommandDef {\n  name: String!\n  schema: String!\n  level: String!\n  aggregateIdField: String\n  mutationField: String!\n  references: [Platform_UIFieldReference!]!\n  allowedStates: [String!]\n}`,
  `type Platform_UIWriteSideDef {\n  name: String!\n  commands: [Platform_UICommandDef!]!\n  linkedViews: [String!]!\n  consistencyRead: String\n  producedEventTypes: [String!]!\n  consumedEventTypes: [String!]!\n}`,
  `type Platform_UIReadSideDef {\n  name: String!\n  queryField: String!\n  schema: String!\n  consumedEventTypes: [String!]!\n  linkedWriteSide: [String!]!\n  labelField: String!\n  searchableFields: [String!]!\n  statusField: String\n}`,
  `type Platform_UIAutomationSliceDef {\n  name: String!\n  consumedEventTypes: [String!]!\n  producedCommandTypes: [String!]!\n}`,
  `type Platform_UIOutboundTranslationSliceDef {\n  name: String!\n  consumedEventTypes: [String!]!\n  inboundCommandTypes: [String!]!\n}`,
  `type Platform_UIInboundTranslationSliceDef {\n  name: String!\n  commandTypes: [String!]!\n}`,
  `type Platform_UIExtensionDef {\n  name: String!\n  delegateNames: [String!]!\n  eventTypes: [String!]!\n  commandTypes: [String!]!\n}`,
  `type Platform_UIDefinitionEntry {\n  pluginId: String!\n  readModels: [Platform_UIReadSideDef!]!\n  stateViewSlices: [Platform_UIReadSideDef!]!\n  stateChangeSlices: [Platform_UIWriteSideDef!]!\n  aggregates: [Platform_UIWriteSideDef!]!\n  automationSlices: [Platform_UIAutomationSliceDef!]!\n  outboundTranslationSlices: [Platform_UIOutboundTranslationSliceDef!]!\n  inboundTranslationSlices: [Platform_UIInboundTranslationSliceDef!]!\n  extensions: [Platform_UIExtensionDef!]!\n}`,
]

let sdlQueryField: string = `  Platform_UIDefinitions: [Platform_UIDefinitionEntry!]!`

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
  ])->JSON.Encode.object

let encodeQueryableDef = (r: queryableDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(r.name)),
    ("queryField", JSON.Encode.string(r.queryField)),
    ("schema", JSON.Encode.string(r.schema)),
    ("consumedEventTypes", encodeStrings(r.consumedEventTypes)),
    ("linkedWriteSide", encodeStrings(r.linkedWriteSide)),
    ("labelField", JSON.Encode.string(r.labelField)),
    ("searchableFields", encodeStrings(r.searchableFields)),
    ("statusField", r.statusField->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
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
  ])->JSON.Encode.object

let encodeAutomationSliceDef = (a: automationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(a.name)),
    ("consumedEventTypes", encodeStrings(a.consumedEventTypes)),
    ("producedCommandTypes", encodeStrings(a.producedCommandTypes)),
  ])->JSON.Encode.object

let encodeOutboundTranslationSliceDef = (o: outboundTranslationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(o.name)),
    ("consumedEventTypes", encodeStrings(o.consumedEventTypes)),
    ("inboundCommandTypes", encodeStrings(o.inboundCommandTypes)),
  ])->JSON.Encode.object

let encodeInboundTranslationSliceDef = (i: inboundTranslationSliceDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(i.name)),
    ("commandTypes", encodeStrings(i.commandTypes)),
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
    ("readModels", def.readModels->Array.map(encodeQueryableDef)->JSON.Encode.array),
    ("stateViewSlices", def.stateViewSlices->Array.map(encodeQueryableDef)->JSON.Encode.array),
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
