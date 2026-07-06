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

let invokeTemplate = (
  ~readModelName: string,
  ~kind: string,
  ~index: option<string>=?,
  ~authTable: option<string>=?,
  ~authGroup: option<string>=?,
) => {
  let indexFrag = switch index {
  | Some(ix) => `\n      index: '${ix}',`
  | None => ""
  }
  let authFrag = switch (authTable, authGroup) {
  | (Some(t), Some(g)) => `\n      authTable: '${t}',\n      authGroup: '${g}',`
  | _ => ""
  }
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      readModelName: '${readModelName}',
      kind: '${kind}',${indexFrag}${authFrag}
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

// Cross-table field resolver (@resolves/@resolvesMany, B3.2c): on a parent
// entity type's field, carrying the parent object (ctx.source) + baked target
// metadata (`extra`). `sourceType` is the parent read model (used only for auth
// scoping in dispatch); `target` is the target read model's binding key.
let invokeFieldTemplate = (~sourceType: string, ~kind: string, ~target: string, ~extra: string) =>
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  return {
    operation: 'Invoke',
    payload: {
      readModelName: '${sourceType}',
      kind: '${kind}',
      target: '${target}',
      source: ctx.source,
      arguments: ctx.args,${extra}
      identity: ${identityBlock}
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

let make: ReventlessCore.QueryDb_Adapter.resolversMaker<api, role> = (
  ~name: string,
  ~api: api,
  ~apiRole as _: role,
  ~dataSourceName,
  ~indexes: array<indexConfig>,
  ~subIdField,
  ~idResolverConfigs: array<idResolverConfig>,
  ~idsResolverConfigs: array<idsResolverConfig>,
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
  let returnTypeName = switch registryEntry {
  | Some({returnTypeName: rt}) => rt
  | None => name
  }

  // Register the binding info the shared Lambda's env config needs (the entry
  // point gets indexes/subIdField/schema from the spec module; labelField and
  // includeIdParam come from this deploy-time registry). Keyed by spec name.
  PgQueryResolver_Builder.register({readModelName: name, labelField, includeIdParam})

  // Relay node type → this read model (for the shared node(id) resolver, B3.2c).
  // Only entities addressable by id participate in node resolution.
  if includeIdParam {
    PgQueryResolver_Builder.registerNodeType(~typeName=returnTypeName, ~readModelName=name)
  }

  let mkResolver = (~resolverName, ~field, ~kind, ~index=?, ~authTable=?, ~authGroup=?) =>
    Resolver.makeUnitJsResolver(
      ~name=resolverName,
      ~api,
      ~dataSourceName,
      ~type_="Query"->Pulumi.Input.make,
      ~field=field->Pulumi.Input.make,
      ~code=invokeTemplate(~readModelName=name, ~kind, ~index?, ~authTable?, ~authGroup?),
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

    // Sub-id connection — {single}Items(id, filter, …); only when subId configured.
    let items = switch subIdField {
    | Some(_) => [
        mkResolver(
          ~resolverName=fieldNameForSingle->String.capitalize ++ "Items",
          ~field=fieldNameForSingle ++ "Items",
          ~kind="items",
        ),
      ]
    | None => []
    }

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

    // Per-index equality queries: {single}By{Index}. A group-restricted index
    // (indexConfig.authorization) bakes the auth-table pipeline params — the
    // Lambda verifies group membership + ownership against the auth read model.
    let byIndex = indexes->Array.map((ic: indexConfig) => {
      let index = ic.index
      let resolverName =
        fieldNameForSingle->String.capitalize ++ "By" ++ index->stripLeadingBy->String.capitalize
      let field = fieldNameForSingle ++ "By" ++ index->stripLeadingBy->String.capitalize
      switch ic.authorization {
      | Some({tableName, group}) =>
        mkResolver(
          ~resolverName,
          ~field,
          ~kind="index",
          ~index,
          ~authTable=tableName->String.capitalize,
          ~authGroup=group,
        )
      | None => mkResolver(~resolverName, ~field, ~kind="index", ~index)
      }
    })

    // @resolves — single cross-table field resolver on this (parent) type. The
    // target's binding key is its capitalized spec name (mirrors how the binding
    // registry is keyed); the parent object flows via ctx.source.
    let idResolvers = idResolverConfigs->Array.map(config => {
      let {source: {idField, subId, resolvedField}, target} = config
      let targetKey = target.tableName->String.capitalize
      let (field, multi) = switch resolvedField {
      | Single(f) => (f, false)
      | Multi(f) => (f, true)
      }
      let targetFrag = switch target.idField {
      | Index(ix) => `\n      targetIndex: '${ix}',\n      targetIndexIdField: '${ix}',`
      | IndexWithId(ix, idf) => `\n      targetIndex: '${ix}',\n      targetIndexIdField: '${idf}',`
      | Id => ""
      }
      let subIdFrag = switch subId {
      | Field(f) => `\n      sourceSubId: { kind: 'field', name: '${f}' },`
      | Argument(a) => `\n      sourceSubId: { kind: 'arg', name: '${a}' },`
      | NoSubId => ""
      }
      let extra =
        `\n      sourceIdField: '${idField}',\n      multi: ${multi ? "true" : "false"},` ++
        targetFrag ++
        subIdFrag
      Resolver.makeUnitJsResolver(
        ~name=name ++ field->String.capitalize,
        ~api,
        ~dataSourceName,
        ~type_=name->Pulumi.Input.make,
        ~field=field->Pulumi.Input.make,
        ~code=invokeFieldTemplate(~sourceType=name, ~kind="resolveOne", ~target=targetKey, ~extra),
        ~opts,
      )
    })

    // @resolvesMany — batch cross-table field resolver (BatchGet by ids).
    let idsResolvers = idsResolverConfigs->Array.map(config => {
      let {source: {idsField, resolvedField}, target} = config
      let targetKey = target.tableName->String.capitalize
      let extra = `\n      sourceIdsField: '${idsField}',`
      Resolver.makeUnitJsResolver(
        ~name=name ++ resolvedField->String.capitalize,
        ~api,
        ~dataSourceName,
        ~type_=name->Pulumi.Input.make,
        ~field=resolvedField->Pulumi.Input.make,
        ~code=invokeFieldTemplate(~sourceType=name, ~kind="resolveMany", ~target=targetKey, ~extra),
        ~opts,
      )
    })

    [byId, all]
    ->Array.concat(items)
    ->Array.concat(byIds)
    ->Array.concat(byIndex)
    ->Array.concat(idResolvers)
    ->Array.concat(idsResolvers)
    ->Array.map(Util.AppSync.toResourceNative)
  }

  {ReventlessCore.QueryDb_Adapter.resources: [], resourcesMaker}
}
