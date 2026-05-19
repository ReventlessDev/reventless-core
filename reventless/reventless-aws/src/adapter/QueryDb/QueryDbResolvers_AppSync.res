open PulumiAws.AppSync
// Shadow PulumiAws.AppSync.Resolver with the retrying dynamic-provider adapter
// so resolver creation calls the AppSync SDK directly and retries
// `NotFoundException: No field named X` (the schema-propagation race) with
// exponential backoff. Replaces AppSync_Resolver_Native (aws-native provider)
// which exhibited the same race in production.
// See docs/plans/appsync-resolver-aws-native-retry.md.
module Resolver = AppSync_Resolver_Retrying
open Reventless.ReadModel

let log = ReventlessCore.Logger.fromEnv()

type api = Types.AppSync.api
type role = Types.AppSync.role

type interceptorConfig = {
  dataSourceName: Pulumi.Input.t<string>,
}

/** Deploy-time config for the query interceptor. When set, all top-level Query
    resolvers become pipeline resolvers with an interceptor Lambda function
    preceding the DynamoDB query. Set this before calling `make`. */
let queryInterceptorConfig: ref<option<interceptorConfig>> = ref(None)

let interceptorCode = readModelName =>
  `import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  const isCognito = id != null && id.sub != null;
  return {
    operation: 'Invoke',
    payload: {
      readModelName: '${readModelName}',
      arguments: ctx.args,
      identity: isCognito
        ? {
            userId: id.sub,
            username: id.username,
            groups: id.claims?.['cognito:groups'] ?? [],
            claims: id.claims,
            provider: 'Cognito'
          }
        : id != null
          ? {
              userArn: id.userArn ?? null,
              accountId: id.accountId ?? null,
              username: id.username ?? null,
              provider: 'IAM'
            }
          : null
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
  ~apiRole: role,
  ~dataSourceName,
  ~indexes: array<indexConfig>,
  ~subIdField,
  ~idResolverConfigs: array<idResolverConfig>,
  ~idsResolverConfigs: array<idsResolverConfig>,
  // AWS path enforces authorization via `@aws_auth(cognito_groups: …)` on the
  // SDL fields (see Stage E in docs/plans/host-ui-login-core.md). Accepted but
  // ignored here so the in-memory and AWS resolver maker signatures stay aligned.
  ~authorization as _: Reventless.Authorization.permission,
  ~opts,
) => {
  let dataSourceName = dataSourceName->Pulumi.Output.asInput
  let name = name->String.capitalize
  let registryEntry = ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.get(name)

  // In plugin mode, use plugin-prefixed field names from the registry.
  let fieldNameForSingle = switch registryEntry {
  | Some({singleFieldName}) => singleFieldName
  | None => name->Resolver.Functions.uncapitalize
  }

  // Resolve includeIdParam flag from registry (defaults to true for ReadModels)
  let includeIdParam = switch registryEntry {
  | Some({includeIdParam}) => includeIdParam
  | None => true
  }

  // Resolve connectionSpec flag from registry (defaults to true)
  let connectionSpec = switch registryEntry {
  | Some({connectionSpec}) => connectionSpec
  | None => true
  }

  // Resolve returnTypeName for Relay Node type registry
  let returnTypeName = switch registryEntry {
  | Some({returnTypeName: rt}) => rt
  | None => name
  }

  // Register entity type in the Relay Node type registry for node(id: ID!) resolution
  if includeIdParam {
    NodeResolver_AppSync.registerNodeType(~typeName=returnTypeName, ~dataSourceName)
  }

  // Creates either a unit resolver (no interceptor) or a pipeline resolver
  // (interceptor Lambda → DynamoDB query) depending on queryInterceptorConfig.
  let makeQueryResolver = (~resolverName, ~field, ~code) =>
    switch queryInterceptorConfig.contents {
    | None =>
      Resolver.makeUnitJsResolver(
        ~name=resolverName,
        ~api,
        ~dataSourceName,
        ~type_="Query"->Pulumi.Input.make,
        ~field,
        ~code,
        ~opts,
      )
    | Some({dataSourceName: interceptorDsName}) =>
      let interceptorFn = Function.makeJs(
        ~name=resolverName ++ "Interceptor",
        ~api,
        ~dataSource=interceptorDsName,
        ~code=interceptorCode(name),
        ~opts,
      )
      let queryFn = Function.makeJs(
        ~name=resolverName ++ "Query",
        ~api,
        ~dataSource=dataSourceName,
        ~code,
        ~opts,
      )
      Resolver.makePipelineJsResolver(
        ~name=resolverName,
        ~api,
        ~type_="Query"->Pulumi.Input.make,
        ~field,
        ~code=Resolver.Functions.pipelinePassThrough,
        ~functions=[interceptorFn, queryFn],
        ~opts,
      )
    }

  let fieldNameForAll = switch registryEntry {
  | Some({listFieldName}) => listFieldName
  | None => name ++ "s"
  }

  // All resolver resources are deferred into resourcesMaker so they are only
  // created inside builderOutputs.apply(...) — which depends on schemaPushed.
  // This prevents a race condition where AppSync resolvers are deployed before
  // the schema push completes and the new fields are ACTIVE in AppSync.
  let resourcesMaker: ReventlessCore.QueryDb.resolversResourcesMaker = allQueryDbs => {
    let resolverByIdSingle = if includeIdParam {
      makeQueryResolver(
        ~resolverName=fieldNameForSingle->String.capitalize,
        ~field=fieldNameForSingle->Pulumi.Input.make,
        ~code=switch subIdField {
        | Some(sortField) => Resolver.Functions.queryByIdSort(sortField)
        | None => Resolver.Functions.getItemById
        },
      )
    } else {
      makeQueryResolver(
        ~resolverName=fieldNameForSingle->String.capitalize,
        ~field=fieldNameForSingle->Pulumi.Input.make,
        ~code=Resolver.Functions.listAllItems,
      )
    }
    let resolverByIdMultiple = if includeIdParam {
      subIdField->Option.map(sortField =>
        makeQueryResolver(
          ~resolverName=fieldNameForSingle->String.capitalize ++ "Items",
          ~field=(fieldNameForSingle ++ "Items")->Pulumi.Input.make,
          ~code=Resolver.Functions.queryItemsWithSortConditions(sortField),
        )
      )
    } else {
      None
    }
    let labelField = switch registryEntry {
    | Some({labelField: ?lf}) => lf->Option.getOr("id")
    | None => "id"
    }
    // Derive server-side filter / sort capability from the registered state schema
    // (Phase 1's deriveServerCapability). Empty arrays when the schema isn't
    // registered or has no indexable fields — the resolver template emits the same
    // SDL the in-memory adapter does, so the AWS Filter / OrderBy stays in lockstep
    // with the SDL emitted by GraphQL_FragmentGenerator at runtime.
    let stateSchemaOpt = ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.get(name)
    let capability = switch stateSchemaOpt {
    | Some(s) => ReventlessCore.GraphQL_FragmentGenerator.deriveServerCapability(s)
    | None => ReventlessCore.GraphQL_FragmentGenerator.emptyCapability
    }
    let filterFieldNames = capability.filterFields->Array.map(f => f.name)
    let rangeFieldNames =
      capability.filterFields->Array.filterMap(f => f.range ? Some(f.name) : None)
    let sortFieldNames = capability.sortFields
    // Deploy-time warning when a `@scanSort` field is not also the sort key of any
    // table or GSI — the resolver can still serve the request, but it will be a
    // JS-runtime per-page sort over a full Scan (expensive in production).
    switch stateSchemaOpt {
    | Some(s) =>
      let knownSortFields =
        switch subIdField {
        | Some(f) => [f]
        | None => []
        }->Array.concat(indexes->Array.filterMap(({subIdField: ?sf}) => sf))
      ReventlessCore.GraphQL_FragmentGenerator.validateScanSortAlignment(
        ~schema=s,
        ~readModelName=name,
        ~knownSortFields,
      )->Array.forEach(msg => log.warn(~comp="QueryDbResolvers_AppSync", msg))
    | None => ()
    }
    let resolverAll = makeQueryResolver(
      ~resolverName=fieldNameForAll->String.capitalize,
      ~field=fieldNameForAll->Pulumi.Input.make,
      ~code=if connectionSpec {
        Resolver.Functions.listAllItemsConnection(
          ~labelField,
          ~filterFields=filterFieldNames,
          ~rangeFields=rangeFieldNames,
          ~sortFields=sortFieldNames,
        )
      } else {
        Resolver.Functions.listAllItems
      },
    )
    let resolversByIndex = indexes->Array.map(({index} as indexConfig) => {
      // Strip a leading "by" from the index name before capitalizing to avoid
      // double "By" in the generated field name (e.g. index "byPlugin" → "ByPlugin",
      // not "ByByPlugin"). Uses the plugin-prefixed fieldNameForSingle so the
      // resolver name is properly namespaced (e.g. "schemaHistoryByPlugin", not
      // "SchemaHistoryByByPlugin" from the raw entity name).
      let stripLeadingBy = s =>
        if s->String.startsWith("by") && s->String.length > 2 {
          s->String.slice(~start=2, ~end=s->String.length)
        } else {
          s
        }
      let resolverName =
        fieldNameForSingle->String.capitalize ++
        "By" ++
        (index->stripLeadingBy->String.capitalize)
      let fieldName =
        fieldNameForSingle ++
        "By" ++
        (index->stripLeadingBy->String.capitalize)
      let idField = indexConfig.idField->Option.getOr(index)
      switch indexConfig.authorization {
      | None =>
        Resolver.makeUnitJsResolver(
          ~name=resolverName,
          ~api,
          ~dataSourceName,
          ~type_="Query"->Pulumi.Input.make,
          ~field=fieldName->Pulumi.Input.make,
          ~code=switch indexConfig.subIdField {
          | Some(sortField) =>
            Resolver.Functions.queryByIndexSortFiltered(~index, ~idField, ~sortField)
          | None => Resolver.Functions.queryByIndexFiltered(~index, ~idField)
          },
          ~opts,
        )
      | Some({tableName, group}) =>
        let authDataSource = DataSource.makeDynamoDBDataSourceWithTableName(
          ~name=resolverName ++ "Auth",
          ~api,
          ~tableName=(
            allQueryDbs
            ->ReventlessCore.Util.QueryDb.getLocalStorageResources(tableName)
            ->Util.DynamoDb.findResource
          ).name,
          ~serviceRole=apiRole,
          ~opts,
        )
        let authFunction = Function.makeJs(
          ~name=resolverName ++ "Auth",
          ~api,
          ~dataSource=authDataSource.name->Pulumi.Output.asInput,
          ~code=Resolver.Functions.authorizeIndexedAccess(~index, ~group),
          ~opts,
        )
        let queryFunction = Function.makeJs(
          ~name=resolverName,
          ~api,
          ~dataSource=dataSourceName,
          ~code=Resolver.Functions.queryByIndexFiltered(~index, ~idField),
          ~opts,
        )
        Resolver.makePipelineJsResolver(
          ~name=resolverName,
          ~api,
          ~type_="Query"->Pulumi.Input.make,
          ~field=fieldName->Pulumi.Input.make,
          ~code=Resolver.Functions.pipelinePassThrough,
          ~functions=[authFunction, queryFunction],
          ~opts,
        )
      }
    })

    let storageResource = (~pluginName: option<string>, ~tableName: string) =>
      allQueryDbs
      ->ReventlessCore.Plugin_Helpers.getStorageResources(pluginName, tableName)
      ->Util.DynamoDb.findResourceInOutput
      ->ReventlessCore.Adapter.outputToResource

    let generateCode = (~storageResource: ReventlessInfra.Adapter.resource, ~template) =>
      storageResource.name
      ->Pulumi.Output.apply(realTableName => template(realTableName))
      ->Pulumi.Output.asInput

    // Batched-by-ids field: BatchGetItem against the projection's own DDB
    // table. Single-key tables only — matches the SDL emitted by
    // GraphQL_FragmentGenerator (composite tables skip this field). Uses
    // the storageResource/generateCode helpers above to interpolate the
    // real DDB table name into the resolver code (BatchGetItem's `tables`
    // map keys on the literal table name).
    let resolverByIds = if includeIdParam && subIdField === None {
      let storage = storageResource(~pluginName=None, ~tableName=name)
      let byIdsField = fieldNameForAll ++ "ByIds"
      Some(
        makeQueryResolver(
          ~resolverName=byIdsField->String.capitalize,
          ~field=byIdsField->Pulumi.Input.make,
          ~code=generateCode(
            ~storageResource=storage,
            ~template=Resolver.Functions.batchGetItemsByIds,
          ),
        ),
      )
    } else {
      None
    }

    let idResolvers = idResolverConfigs->Array.map(config => {
      let {
        source: {idField: sourceIdField, subId: sourceSubId, resolvedField},
        target: {tableName, idField: targetId} as target,
      }: idResolverConfig = config
      let (index, targetIdField) = switch targetId {
      | Index(index) => (index, index)
      | IndexWithId(index, targetIdField) => (index, targetIdField)
      | _ => ("", "")
      }
      let storageResource = storageResource(~pluginName=target.pluginName, ~tableName)
      switch resolvedField {
      | Single(field)
      | Multi(field) =>
        let dataSourceName =
          DataSource.makeDynamoDBDataSourceWithTableName(
            ~name=name ++ (field->String.capitalize ++ "Resolver"),
            ~api,
            ~tableName=storageResource.name,
            ~serviceRole=apiRole,
            ~opts,
          ).name->Pulumi.Output.asInput

        Resolver.makeUnitJsResolver(
          ~name=name ++ field->String.capitalize,
          ~api,
          ~dataSourceName,
          ~type_=name->Pulumi.Input.make,
          ~field=field->Pulumi.Input.make,
          ~code=switch (targetId, sourceSubId, target.subIdField) {
          | (Id, Field(sourceSortField), Some(targetSortField)) =>
            Resolver.Functions.resolveIdSort(~sourceIdField, ~sourceSortField, ~targetSortField)
          | (Id, Argument(sourceSortArgument), Some(targetSortField)) =>
            Resolver.Functions.resolveIdSortArgument(
              ~sourceIdField,
              ~sourceSortArgument,
              ~targetSortField,
            )
          | (Id, _, _) => Resolver.Functions.resolveId(~sourceIdField)

          | (_, Field(sourceSortField), Some(targetSortField)) =>
            Resolver.Functions.resolveIdByIndexSort(
              ~index,
              ~sourceIdField,
              ~targetIdField,
              ~sourceSortField,
              ~targetSortField,
            )
          | (_, Argument(sourceSortArgument), Some(targetSortField)) =>
            Resolver.Functions.resolveIdByIndexSortArgument(
              ~index,
              ~sourceIdField,
              ~targetIdField,
              ~sourceSortArgument,
              ~targetSortField,
            )
          | _ => Resolver.Functions.resolveIdByIndex(~index, ~sourceIdField, ~targetIdField)
          },
          ~opts,
        )
      }
    })

    let idsResolvers = idsResolverConfigs->Array.map(config => {
      let {source: {idsField, resolvedField}, target: {tableName} as target} = config
      let storageResource = storageResource(~pluginName=target.pluginName, ~tableName)

      Resolver.makeUnitJsResolver(
        ~name=name ++ idsField->String.capitalize,
        ~api,
        ~dataSourceName,
        ~type_=name->Pulumi.Input.make,
        ~field=resolvedField->Pulumi.Input.make,
        ~code=generateCode(
          ~storageResource,
          ~template=Resolver.Functions.resolveIds(~idsField, ~sortField=target.subIdField, ...),
        ),
        ~opts,
      )
    })

    let mainResolvers = switch (resolverByIdMultiple, resolverByIds) {
    | (Some(r), Some(byIds)) => [resolverByIdSingle, r, resolverAll, byIds]
    | (Some(r), None) => [resolverByIdSingle, r, resolverAll]
    | (None, Some(byIds)) => [resolverByIdSingle, resolverAll, byIds]
    | (None, None) => [resolverByIdSingle, resolverAll]
    }
    Array.flat([mainResolvers, resolversByIndex, idResolvers, idsResolvers])
    ->Array.map(Util.AppSync.toResourceNative)
  }

  {resources: [], resourcesMaker}
}
