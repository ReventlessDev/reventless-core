// The view of a plugin's visitor request counts (`Reventless.VisitorRequestCount`):
// rows the platform writes as it counts, read by the deployment's operators by id.
// Each platform builds it with its own storage and resolvers and hands it to a
// plugin with a door or view for visitors through `visitorRequestCountsHook`.
// Locally every plugin's view shares the one name, so two such plugins share one.
//
// Who the operators are is read as the view is made, not as this module loads:
// the root states them after its imports have run.

@module("./VisitorRequestCount_Url.mjs") external moduleUrl: string = "url"

let name = Reventless.VisitorRequestCount.queryDbName

/** Whether a plugin has a door or view for visitors, by the rules its fields declare. */
let hasVisitorFields = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): bool =>
  mutationEntries->Array.some(entry =>
    entry.fieldPermissions->Option.mapOr(false, fp =>
      fp->Dict.valuesToArray->Array.some(p => p == Reventless.Authorization.AllowAnonymous)
    )
  ) ||
    queryEntries->Array.some(entry =>
      entry.permission == Some(Reventless.Authorization.AllowAnonymous)
    )

/** The view's fields in the plugin's schema, for operators only. */
let queryEntry = (~plugin: string): ReventlessInfra.Api.querySchemaEntry => {
  let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin, ~queryDbName=name)
  Plugin_Helpers.queryFieldNamesRegistry->Dict.set(name, qn)
  {
    singleFieldName: qn.singleFieldName,
    listFieldName: qn.listFieldName,
    returnTypeName: qn.returnTypeName,
    stateSchema: Reventless.VisitorRequestCount.rowSchema->S.castToUnknown,
    authorization: None,
    permission: Reventless.OwnerScope.operators(),
    connectionSpec: true,
  }
}

/** Expiry is on: each row carries when it goes, per the length of its bucket. */
let expires = 1

module Make = (
  Storage: QueryDb_Adapter.Storage,
  Resolvers: QueryDb_Adapter.Resolvers with type api = Storage.api and type role = Storage.role,
) => {
  let make = (
    ~api: Storage.api,
    ~apiRole: Storage.role,
    ~opts: Pulumi.ComponentResource.options,
  ) => {
    module Spec = {
      module Id = Reventless.Id.String
      let name = name
      let moduleUrl = moduleUrl
      type state = Reventless.VisitorRequestCount.row
      let stateSchema = Reventless.VisitorRequestCount.rowSchema
      let config = Reventless.ReadModel.config()
      let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = None
      type role = Reventless.Role.name
      let authorization: Reventless.Authorization.rule<role> = Reventless.OwnerScope.operators()
      let visibility: Reventless.Visibility.t = Internal
    }
    module Db = QueryDb_Builder.Make(Spec, Storage, Resolvers)
    Db.make(~api, ~apiRole, ~ttl=expires, ~opts)
  }
}
