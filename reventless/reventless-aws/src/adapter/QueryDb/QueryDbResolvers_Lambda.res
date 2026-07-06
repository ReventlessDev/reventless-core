// AppSync resolvers for Postgres-backed read models (B3.2b) — the Lambda-data-
// source parallel to QueryDbResolvers_AppSync's direct DynamoDB resolvers.
//
// Every Query field becomes a thin APPSYNC_JS unit resolver whose `Invoke`
// template carries { readModelName, kind, index?, arguments, identity } to the
// ONE shared PgQueryResolver Lambda (PgQueryResolver_Builder), which dispatches
// via PgQueryResolver_Lambda.dispatch. `dataSourceName` is the shared data
// source's (deferred) name, the same for every Postgres read model.
//
// Field names / includeIdParam / connectionSpec come from the same registry the
// AppSync path reads, so the SDL emitted by GraphQL_FragmentGenerator stays in
// lockstep. Kinds covered: getById, list (connection), index, byIds. Deferred to
// B3.2c: items (sub-id connection), @resolves/@resolvesMany, node, auth-table.

module Resolver = AppSync_Resolver_Retrying
open Reventless.ReadModel

type api = Types.AppSync.api
type role = Types.AppSync.role

// Identity block shared by every Invoke template (Cognito vs IAM), matching the
// shape PgQueryResolver_Lambda decodes (Reventless.Identity.t).
let identityBlock = `id != null && id.sub != null
      ? { userId: id.sub, username: id.username, groups: id.claims?.['cognito:groups'] ?? [], claims: id.claims, provider: 'Cognito' }
      : id != null
        ? { userArn: id.userArn ?? null, accountId: id.accountId ?? null, username: id.username ?? null, provider: 'IAM' }
        : null`

let invokeTemplate = (~readModelName: string, ~kind: string, ~index: option<string>=?) => {
  let indexFrag = switch index {
  | Some(ix) => `\n      index: '${ix}',`
  | None => ""
  }
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      readModelName: '${readModelName}',
      kind: '${kind}',${indexFrag}
      arguments: ctx.args,
      identity: ${identityBlock}
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make
}

let make: ReventlessCore.QueryDb_Adapter.resolversMaker<api, role> = (
  ~name: string,
  ~api: api,
  ~apiRole as _: role,
  ~dataSourceName,
  ~indexes: array<indexConfig>,
  ~subIdField,
  ~idResolverConfigs as _: array<idResolverConfig>,
  ~idsResolverConfigs as _: array<idsResolverConfig>,
  ~authorization as _: Reventless.Authorization.permission,
  ~opts,
) => {
  let dataSourceName = dataSourceName->Pulumi.Output.asInput
  let name = name->String.capitalize
  let registryEntry = ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.get(name)

  let fieldNameForSingle = switch registryEntry {
  | Some({singleFieldName}) => singleFieldName
  | None => name->Resolver.Functions.uncapitalize
  }
  let includeIdParam = switch registryEntry {
  | Some({includeIdParam}) => includeIdParam
  | None => true
  }
  let connectionSpec = switch registryEntry {
  | Some({connectionSpec}) => connectionSpec
  | None => true
  }
  let fieldNameForAll = switch registryEntry {
  | Some({listFieldName}) => listFieldName
  | None => name ++ "s"
  }
  let labelField = switch registryEntry {
  | Some({labelField: ?lf}) => lf->Option.getOr("id")
  | None => "id"
  }

  // Register the binding info the shared Lambda's env config needs (the entry
  // point gets indexes/subIdField/schema from the spec module; labelField and
  // includeIdParam come from this deploy-time registry). Keyed by spec name.
  PgQueryResolver_Builder.register({readModelName: name, labelField, includeIdParam})

  let mkResolver = (~resolverName, ~field, ~kind, ~index=?) =>
    Resolver.makeUnitJsResolver(
      ~name=resolverName,
      ~api,
      ~dataSourceName,
      ~type_="Query"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~code=invokeTemplate(~readModelName=name, ~kind, ~index?),
      ~opts,
    )

  let stripLeadingBy = s =>
    if s->String.startsWith("by") && s->String.length > 2 {
      s->String.slice(~start=2, ~end=s->String.length)
    } else {
      s
    }

  // Resolvers are deferred into resourcesMaker (created inside the schema-pushed
  // builderOutputs.apply, like the AppSync path) — so they only exist after the
  // fields are ACTIVE and after PgQueryResolver_Builder.provision has resolved
  // the shared data source name.
  let resourcesMaker: ReventlessCore.QueryDb.resolversResourcesMaker = _allQueryDbs => {
    // getById (or listAll when the read model has no id param, e.g. singletons).
    let byId = mkResolver(
      ~resolverName=fieldNameForSingle->String.capitalize,
      ~field=fieldNameForSingle,
      ~kind=includeIdParam ? "getById" : "list",
    )

    // Main list — Relay connection (or legacy list when connectionSpec=false).
    let all = mkResolver(
      ~resolverName=fieldNameForAll->String.capitalize,
      ~field=fieldNameForAll,
      ~kind=connectionSpec ? "list" : "list",
    )

    // Batched-by-ids — single-key projections only (mirrors the SDL).
    let byIds = if includeIdParam && subIdField === None {
      let byIdsField = fieldNameForAll ++ "ByIds"
      [
        mkResolver(
          ~resolverName=byIdsField->String.capitalize,
          ~field=byIdsField,
          ~kind="byIds",
        ),
      ]
    } else {
      []
    }

    // Per-index equality queries: {single}By{Index}.
    let byIndex = indexes->Array.map(({index}) => {
      let resolverName =
        fieldNameForSingle->String.capitalize ++ "By" ++ index->stripLeadingBy->String.capitalize
      let field = fieldNameForSingle ++ "By" ++ index->stripLeadingBy->String.capitalize
      mkResolver(~resolverName, ~field, ~kind="index", ~index)
    })

    [byId, all]
    ->Array.concat(byIds)
    ->Array.concat(byIndex)
    ->Array.map(Util.AppSync.toResourceNative)
  }

  {ReventlessCore.QueryDb_Adapter.resources: [], resourcesMaker}
}
