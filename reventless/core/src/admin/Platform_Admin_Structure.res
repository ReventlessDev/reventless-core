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

// Strip the named fields from a derived JSON schema's `properties` map and
// `required` list. Used so Plugin read model metadata announced via
// `Platform_ComponentDefinitions` matches the SDL — fields excluded from the GraphQL
// schema in `PluginBaseFragment` must also disappear from the schema string
// AutoUI consumes, or list-view queries will reference non-existent fields.
let encodeSchemaExcluding = (schema: S.t<unknown>, ~excludeFields: array<string>): string => {
  let derived = schema->SuryToJsonSchema.deriveObjectSchema
  switch derived->JSON.Decode.object {
  | None => derived->JSON.stringify
  | Some(obj) =>
    switch obj->Dict.get("properties")->Option.flatMap(JSON.Decode.object) {
    | None => derived->JSON.stringify
    | Some(props) =>
      excludeFields->Array.forEach(f => props->Dict.delete(f))
      obj->Dict.set("properties", props->JSON.Encode.object)
      switch obj->Dict.get("required")->Option.flatMap(JSON.Decode.array) {
      | None => ()
      | Some(req) =>
        let filtered =
          req
          ->Array.filterMap(JSON.Decode.string)
          ->Array.filter(name => !(excludeFields->Array.includes(name)))
          ->Array.map(JSON.Encode.string)
          ->JSON.Encode.array
        obj->Dict.set("required", filtered)
      }
      obj->JSON.Encode.object->JSON.stringify
    }
  }
}

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

let pluginReadModel: queryableDef = {
  name: "Plugins",
  queryField: Api_Naming.adminField(~name="Plugins"),
  schema: PluginsReadModelSpec.stateSchema
  ->S.castToUnknown
  ->encodeSchemaExcluding(~excludeFields=PluginBaseFragment.pluginUIOnlyExcludeFields),
  consumedEventTypes: [],
  linkedWriteSide: ["Plugin"],
  labelField: "name",
  searchableFields: ["name"],
  // Hand-rolled rather than resolved, but the rung is the same one
  // `labelFieldsFromStateSchema` would report for a field literally named `name`.
  labelFieldSource: Some("convention"),
  // Derived from the spec's `@lifecycle` rather than restated here.
  lifecycleField: Plugin_Structure.lifecycleFieldFromStateSchema(
    ~entityName=PluginsReadModelSpec.name,
    PluginsReadModelSpec.stateSchema->S.castToUnknown,
  ),
  visibility: None,
  chapter: None,
  // The admin fragment hand-declares its query names rather than deriving them from
  // the read-model name, so the singular is taken from the same call
  // `PluginBaseFragment.queryNames.singleFieldName` makes — not singularised here.
  singleQueryField: Some(Api_Naming.adminField(~name="Plugin")),
  // No key field to name: the row id is `name@version` (`Plugin.makeId`), and the
  // state carries the two halves separately rather than the composed key. `None`
  // is the honest answer — the same one the resolver ladder reaches for a state
  // with no `*Id` field.
  idField: None,
  idFieldSource: None,
  requiredAccess: None,
  ownerField: None,
  retiredField: None,
  retiredValues: None,
  namedWhenRetired: None,
}

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
}
