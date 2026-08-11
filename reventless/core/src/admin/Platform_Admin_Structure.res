// Synthetic pluginStructure for the built-in Platform_Admin plugin.
//
// The admin's Plugin aggregate + Plugin read model are
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

// Args schema for the synthetic Auto UI metadata. Activate/Deactivate are payload-less
// `PluginSpec.command` variants on the wire — the auto-resolver flow injects `id: ID!`.
// Keep a local schema here so Auto UI's command-form metadata stays accurate.
@schema
type idArgs = {id: @s.matches(Reventless.DcbTag.string) string}

// `aggregateIdField: Some("id")` pre-fills the form's `id` input from the
// selected list row. The auto-codegen path would emit this for any
// Instance-level command whose schema has a DCB-tagged id field; the
// hand-rolled definitions below have to mirror that.

// `allowedStates` mirrors the PluginBehavior accept/reject branches: Activate
// is meaningful only on Inactive plugins; Deactivate is meaningful on
// Connected or Disconnected ones. Strings here must match the variant
// constructor names that PluginsReadModelSpec.status serialises to.
let activateCommand: commandDef = {
  name: "Activate",
  schema: idArgsSchema->S.castToUnknown->encodeSchema,
  level: Instance,
  aggregateIdField: Some("id"),
  mutationField: Api_Naming.adminField(~name="Plugin_Activate"),
  references: [],
  allowedStates: Some(["Inactive"]),
  targetState: None,
  apiExposed: Some(true),
}

let deactivateCommand: commandDef = {
  name: "Deactivate",
  schema: idArgsSchema->S.castToUnknown->encodeSchema,
  level: Instance,
  aggregateIdField: Some("id"),
  mutationField: Api_Naming.adminField(~name="Plugin_Deactivate"),
  references: [],
  allowedStates: Some(["Connected", "Disconnected"]),
  targetState: None,
  apiExposed: Some(true),
}

let pluginAggregate: writableDef = {
  name: "Plugin",
  commands: [activateCommand, deactivateCommand],
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
  statusField: Some("status"),
  visibility: None,
  chapter: None,
  // The admin fragment hand-declares its query names rather than deriving them from
  // the read-model name, so the singular is taken from the same call
  // `PluginBaseFragment.queryNames.singleFieldName` makes — not singularised here.
  singleQueryField: Some(Api_Naming.adminField(~name="Plugin")),
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
