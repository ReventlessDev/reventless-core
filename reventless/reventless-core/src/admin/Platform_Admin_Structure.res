// Synthetic pluginStructure for the built-in Platform_Admin plugin.
//
// The admin's Plugin aggregate + Plugin/PlatformEventGraph read models are
// wired into the GraphQL schema via PluginBaseFragment, not through the
// regular ~aggregates / ~readModels arrays passed to Admin.construct. As a
// result, Plugin_Structure.make never sees them, and the in-memory Platform
// never seeds them into pluginStructuresStore — so the host shell's Auto UI
// has no metadata for the admin plugin and renders nothing for it.
//
// This module produces an equivalent structure by hand using the same field
// naming conventions (Api_Naming.adminField) and the mutation arg schemas
// from PluginBaseFragment.

open Reventless.Plugin

let pluginId = "Platform"

let pluginName = pluginId

let encodeSchema = (schema: S.t<unknown>): string =>
  schema->SuryToJsonSchema.deriveObjectSchema->JSON.stringify

// Strip the named fields from a derived JSON schema's `properties` map and
// `required` list. Used so Plugin read model metadata announced via
// `Platform_UIDefinitions` matches the SDL — fields excluded from the GraphQL
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

// Args schema for the synthetic Auto UI metadata. Activate/Deactivate are payload-less
// `PluginSpec.command` variants on the wire — the auto-resolver flow injects `id: ID!`.
// Keep a local schema here so Auto UI's command-form metadata stays accurate.
@schema
type idArgs = {id: @s.matches(Reventless.DcbTag.string) string}

// `aggregateIdField: Some("id")` pre-fills the form's `id` input from the
// selected list row. The auto-codegen path would emit this for any
// Instance-level command whose schema has a DCB-tagged id field; the
// hand-rolled definitions below have to mirror that.

let activateCommand: commandDef = {
  name: "Activate",
  schema: idArgsSchema->S.castToUnknown->encodeSchema,
  level: Instance,
  aggregateIdField: Some("id"),
  mutationField: Api_Naming.adminField(~name="Plugin_Activate"),
  references: [],
}

let deactivateCommand: commandDef = {
  name: "Deactivate",
  schema: idArgsSchema->S.castToUnknown->encodeSchema,
  level: Instance,
  aggregateIdField: Some("id"),
  mutationField: Api_Naming.adminField(~name="Plugin_Deactivate"),
  references: [],
}

let pluginAggregate: writableDef = {
  name: "Plugin",
  commands: [activateCommand, deactivateCommand],
  producedEventTypes: [],
  consumedEventTypes: [],
  linkedViews: ["Plugin"],
  consistencyRead: None,
}

let pluginReadModel: queryableDef = {
  name: "Plugin",
  queryField: Api_Naming.adminField(~name="Plugins"),
  schema: PluginReadModelSpec.stateSchema
  ->S.castToUnknown
  ->encodeSchemaExcluding(~excludeFields=PluginBaseFragment.pluginUIOnlyExcludeFields),
  consumedEventTypes: [],
  linkedWriteSide: ["Plugin"],
  labelField: "name",
  searchableFields: ["name"],
}

let eventGraphReadModel: queryableDef = {
  name: "PlatformEventGraph",
  queryField: Api_Naming.adminField(~name="PlatformEventGraphs"),
  schema: Platform_EventGraphReadModelSpec.stateSchema->S.castToUnknown->encodeSchema,
  consumedEventTypes: [],
  linkedWriteSide: [],
  labelField: "pluginName",
  searchableFields: ["pluginName"],
}

let structure: pluginStructure = {
  readModels: [pluginReadModel, eventGraphReadModel],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [pluginAggregate],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
}
