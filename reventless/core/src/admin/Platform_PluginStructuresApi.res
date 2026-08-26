// SDL types and JSON encoder for the `Platform_PluginStructures` GraphQL query —
// the COMPLETE plugin structure, for developer tooling.
//
// Why this is a separate query rather than more fields on
// `Platform_ComponentDefinitions`: the two have different contracts, and the
// difference is not cosmetic.
//
//   Platform_ComponentDefinitions  the deployed AutoUI's menu, drill-down pages and
//                                  queryable defs. Internal ReadModels /
//                                  StateViewSlices are filtered OUT — showing them
//                                  would put components in an end user's menu that
//                                  the author marked as not-for-display.
//   Platform_PluginStructures      what the plugin actually IS. Nothing is filtered,
//                                  and the producer-side `extensionPoints` are
//                                  carried, because a tool drawing the domain graph
//                                  has to see every component and every cross-plugin
//                                  bridge or the graph it draws is a lie.
//
// Folding both into one field would mean either leaking Internal components into
// AutoUI or hiding them from tooling; there is no filter setting that is right for
// both. The component-level types are shared with `Platform_ComponentDefinitionsApi`
// (one component has one shape), so only the entry type and the two structure-level
// collections live here.
//
// Both adapters resolve this from the same persisted `pluginStructure`, so a single
// client query string works against a deployed platform and an in-memory one.

open Reventless.Plugin

let sdlTypes: array<string> = [
  // The port's translation table — see `publishedEventDef`.
  `type Platform_PublishedEventDef {\n  name: String!\n  fromEventTypes: [String!]!\n}`,
  // Producer side of an extension point. `commandTypes` is null for a
  // notification-only (`command = unit`) extension point — see `extensionPointDef`.
  `type Platform_ExtensionPointDef {\n  name: String!\n  delegateNames: [String!]!\n  sourceEventTypes: [String!]!\n  commandTypes: [String!]\n  publishedEvents: [Platform_PublishedEventDef!]\n}`,
  `type Platform_RequiredStoreDeclaration {\n  store: String!\n  component: String!\n  field: String!\n  annotation: String\n}`,
  // `extensionPoints` / `requiredStores` / `requiredStoreDeclarations` are nullable
  // lists, not `[T!]!`: all three are optional on `pluginStructure` so that plugin
  // definitions persisted before the field existed still decode. A structure written
  // by an older deploy sends null, and null is the honest answer — an empty list
  // would claim the plugin has no extension points when the truth is that the
  // deployment cannot say.
  `type Platform_PluginStructureEntry {\n  pluginId: String!\n  readModels: [Platform_ReadSideDef!]!\n  stateViewSlices: [Platform_ReadSideDef!]!\n  stateChangeSlices: [Platform_WriteSideDef!]!\n  aggregates: [Platform_WriteSideDef!]!\n  automationSlices: [Platform_AutomationSliceDef!]!\n  outboundTranslationSlices: [Platform_OutboundTranslationSliceDef!]!\n  inboundTranslationSlices: [Platform_InboundTranslationSliceDef!]!\n  extensions: [Platform_ExtensionDef!]!\n  extensionPoints: [Platform_ExtensionPointDef!]\n  requiredStores: [String!]\n  requiredStoreDeclarations: [Platform_RequiredStoreDeclaration!]\n}`,
]

let sdlQueryField: string = `  Platform_PluginStructures: [Platform_PluginStructureEntry!]!`

let encodeExtensionPointDef = (e: extensionPointDef): JSON.t =>
  Dict.fromArray([
    ("name", JSON.Encode.string(e.name)),
    ("delegateNames", Platform_ComponentDefinitionsApi.encodeStrings(e.delegateNames)),
    ("sourceEventTypes", Platform_ComponentDefinitionsApi.encodeStrings(e.sourceEventTypes)),
    (
      "commandTypes",
      e.commandTypes->Option.mapOr(JSON.Encode.null, Platform_ComponentDefinitionsApi.encodeStrings),
    ),
    (
      "publishedEvents",
      e.publishedEvents->Option.mapOr(JSON.Encode.null, published =>
        published
        ->Array.map(p =>
          Dict.fromArray([
            ("name", JSON.Encode.string(p.name)),
            (
              "fromEventTypes",
              Platform_ComponentDefinitionsApi.encodeStrings(p.fromEventTypes),
            ),
          ])->JSON.Encode.object
        )
        ->JSON.Encode.array
      ),
    ),
  ])->JSON.Encode.object

let encodeRequiredStoreDeclaration = (d: requiredStoreDeclaration): JSON.t =>
  Dict.fromArray([
    ("store", JSON.Encode.string(d.store)),
    ("component", JSON.Encode.string(d.component)),
    ("field", JSON.Encode.string(d.field)),
    ("annotation", d.annotation->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
  ])->JSON.Encode.object

// Deliberately NOT filtered by `isPublicQueryable`: that filter is the AutoUI
// contract, and applying it here would silently drop Internal components from the
// graph a developer tool draws.
let encodePluginStructureEntry = (~pluginId: string, def: pluginStructure): JSON.t =>
  Dict.fromArray([
    ("pluginId", JSON.Encode.string(Plugin.name(pluginId))),
    (
      "readModels",
      def.readModels->Array.map(Platform_ComponentDefinitionsApi.encodeQueryableDef)->JSON.Encode.array,
    ),
    (
      "stateViewSlices",
      def.stateViewSlices
      ->Array.map(Platform_ComponentDefinitionsApi.encodeQueryableDef)
      ->JSON.Encode.array,
    ),
    (
      "stateChangeSlices",
      def.stateChangeSlices
      ->Array.map(Platform_ComponentDefinitionsApi.encodeWritableDef)
      ->JSON.Encode.array,
    ),
    (
      "aggregates",
      def.aggregates->Array.map(Platform_ComponentDefinitionsApi.encodeWritableDef)->JSON.Encode.array,
    ),
    (
      "automationSlices",
      def.automationSlices
      ->Array.map(Platform_ComponentDefinitionsApi.encodeAutomationSliceDef)
      ->JSON.Encode.array,
    ),
    (
      "outboundTranslationSlices",
      def.outboundTranslationSlices
      ->Array.map(Platform_ComponentDefinitionsApi.encodeOutboundTranslationSliceDef)
      ->JSON.Encode.array,
    ),
    (
      "inboundTranslationSlices",
      def.inboundTranslationSlices
      ->Array.map(Platform_ComponentDefinitionsApi.encodeInboundTranslationSliceDef)
      ->JSON.Encode.array,
    ),
    (
      "extensions",
      def.extensions->Array.map(Platform_ComponentDefinitionsApi.encodeExtensionDef)->JSON.Encode.array,
    ),
    (
      "extensionPoints",
      def.extensionPoints->Option.mapOr(JSON.Encode.null, eps =>
        eps->Array.map(encodeExtensionPointDef)->JSON.Encode.array
      ),
    ),
    (
      "requiredStores",
      def.requiredStores->Option.mapOr(
        JSON.Encode.null,
        Platform_ComponentDefinitionsApi.encodeStrings,
      ),
    ),
    (
      "requiredStoreDeclarations",
      def.requiredStoreDeclarations->Option.mapOr(JSON.Encode.null, ds =>
        ds->Array.map(encodeRequiredStoreDeclaration)->JSON.Encode.array
      ),
    ),
  ])->JSON.Encode.object
