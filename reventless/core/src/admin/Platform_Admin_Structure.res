// Synthetic pluginStructure for the built-in Platform_Admin plugin.
//
// The admin's Plugin aggregate + Plugin read model are
// wired into the GraphQL schema via PluginBaseFragment, not through the
// regular ~aggregates / ~readModels arrays passed to Admin.construct. As a
// result, Plugin_Structure.make never sees them, and the in-memory Platform
// never seeds them into pluginStructuresStore — so the host shell's Auto UI
// has no metadata for the admin plugin and renders nothing for it.
//
// This module assembles the equivalent structure from `PluginSpec` /
// `PluginsReadModelSpec` directly, through the same module-level extractors
// `make` uses for every ordinary plugin. It cannot call `make` itself — the
// platform has no `module(Aggregate.T)` to hand it at structure-assembly time —
// but the extractors take schemas, which is all this needs.

open Reventless.Plugin

let pluginId = "Platform"

let pluginName = pluginId

let commandSchema = PluginSpec.commandSchema->S.castToUnknown

// Every variant of `PluginSpec.command`, walked by the same `extractCommandDefs`
// an ordinary aggregate goes through. The hand-written alternative described the
// arguments with a local `{id}` schema while the generated SDL declared
// `Platform_Plugin_Activate(_0: String!, id: ID!)`, so AutoUI built a mutation
// missing a required argument and every admin row action was rejected before it
// reached the aggregate. Deriving from `commandSchema` — the same schema the SDL
// is generated from — cannot reproduce that class of fault.
//
// `mutationFieldFor` is composed the way `PluginBaseFragment` composes the field
// it generates, so the two cannot name it differently. The `@noApi` protocol
// variants come back too, carrying `apiExposed: false` and the empty
// `mutationField` sentinel: metadata about an edge, not a way to invoke it.
let pluginCommands: array<commandDef> = Plugin_Structure.extractCommandDefs(
  ~isAggregate=true,
  ~mutationFieldFor=variantName =>
    Api_Naming.adminField(~name=PluginSpec.name ++ "_" ++ variantName),
  ~commandAuthorization=PluginSpec.commandAuthorization->Obj.magic,
  ~commandTransition=PluginSpec.commandTransition->Obj.magic,
  commandSchema,
)

let pluginAggregate: writableDef = {
  name: "Plugin",
  commands: pluginCommands,
  producedEventTypes: [],
  consumedEventTypes: [],
  linkedViews: ["Plugins"],
  consistencyRead: None,
  events: [],
  // Derived rather than left empty like `events` above: the two admin commands can
  // be refused, and `[]` here would read as "this aggregate never rejects". Uses
  // the same walk `Plugin_Structure` applies to every other write side.
  errors: Plugin_Structure.extractErrorDefs(PluginSpec.errorSchema->S.castToUnknown),
  chapter: None,
}

let pluginReadModel: queryableDef = Plugin_Structure.queryableDefFromSpec(
  ~plugin=pluginId,
  ~name=PluginsReadModelSpec.name,
  ~stateSchema=PluginsReadModelSpec.stateSchema->S.castToUnknown,
  ~authorization=PluginsReadModelSpec.authorization,
  ~linkedWriteSide=["Plugin"],
)

let structure: pluginStructure = {
  readModels: [pluginReadModel],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [pluginAggregate],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
  requiredCapabilities: None,
  traitDeclarations: None,
}

/** The definition the platform's own EventCollector ships as its
    `pluginDefinition.json` asset, and hands to `Platform_Admin_Callback`.

    The admin IS the Plugin extension point, so it never travels the connect
    handshake and every field here is a placeholder. The asset is still read back
    on the same path as every other plugin's, so it is declared as a value and
    encoded through `pluginDefinitionSchema` at both sites rather than written out
    as JSON: the hand-written twin that used to live in the AWS builder predated
    `dcbEventLog` and `kind` and silently stopped matching the schema, which only
    surfaced once the read side decoded instead of casting. */
let internalPluginDefinition: pluginDefinition = {
  id: pluginId ++ "@INTERNAL",
  name: pluginId,
  version: "INTERNAL",
  extensionPoints: [],
  extensions: [],
  eventCollector: "NOT-SET",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  structure: None,
  dcbEventLog: None,
  kind: Domain,
}
