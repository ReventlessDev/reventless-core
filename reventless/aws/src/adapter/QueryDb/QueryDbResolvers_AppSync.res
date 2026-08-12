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

/** The discriminator attribute whose absence marks an internal bookkeeping row for a
    read model whose physical DynamoDB table co-hosts rows written outside the projection.
    Only the Plugins admin RM has this: its table also holds `deploy-schema:*` /
    `plugin-info:*` / `deploy-schema-hash:*` rows (Platform.res preResolversSchemaHook)
    that carry no `name`. Returning `Some(attr)` makes the Connection Scan emit an
    `attribute_exists(#attr)` filter so those rows never reach the non-null GraphQL schema.
    `name` is the already-capitalized read-model name (spec name, e.g. "Plugins").
    See docs/plans/platform-plugins-admin-connection-null-rows.md. */
let internalRowRequiredAttr = (name: string): option<string> =>
  name == "Plugins" ? Some("name") : None

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

  // The interceptor step for one Query resolver, or `None` when this deployment
  // did not switch interception on. Provisioning it is the framework's job — see
  // `QueryInterceptor_Provisioning`; the first Query resolver under a plugin
  // creates the data source and the rest reuse it.
  //
  // **Every top-level Query field on this read model gets one when interception
  // is on, whatever its access path.** The hook reports `readModelName`, so all
  // of them resolve the SAME read model and a consumer counting resolutions must
  // see all of them or its number is a function of which access paths a model
  // happens to expose — two models with identical traffic would report different
  // totals because one is queried through an index. A partial pipeline here would
  // make that skew invisible rather than absent.
  let interceptorFunction = (~resolverName) =>
    switch QueryInterceptor_Provisioning.dataSourceName(~api, ~opts) {
    | Off => None
    | On(interceptorDsName) =>
      Some(
        Function.makeJs(
          ~name=resolverName ++ "Interceptor",
          ~api,
          ~dataSource=interceptorDsName,
          ~code=interceptorCode(name),
          ~opts,
        ),
      )
    }

  // Creates either a unit resolver (no interceptor) or a pipeline resolver
  // (interceptor Lambda → DynamoDB query), for the Query fields that have no
  // second step of their own.
  let makeQueryResolver = (~resolverName, ~field, ~code) =>
    switch interceptorFunction(~resolverName) {
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
    | Some(interceptorFn) =>
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
    | Some(s) => ReventlessCore.GraphQL_FragmentGenerator.deriveServerCapability(~entityName=name, s)
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
    // The Plugins admin RM's DynamoDB table co-hosts deploy-time infra rows
    // (`deploy-schema:<name>`, `plugin-info:<name>`, `deploy-schema-hash:<apiId>`)
    // written directly by the platform (Platform.res preResolversSchemaHook), not by
    // the projection. Those rows carry no `name` attribute, so an unfiltered Scan
    // resolves `name: String!` to null → non-null violation that nulls the entire
    // Platform_PluginConnection. Exclude them with an `attribute_exists(#name)` filter
    // (prefix-agnostic: real plugin rows always carry `name`, internal rows never do).
    // See docs/plans/platform-plugins-admin-connection-null-rows.md.
    let requireAttribute = internalRowRequiredAttr(name)
    // Derived from the same schema `capability` came from, so the two cannot
    // disagree about this read model's fields.
    let ownerField = switch stateSchemaOpt {
    | Some(s) => Reventless.Owner.fieldNames(s)->Array.get(0)
    | None => None
    }
    // A DynamoDB FilterExpression is applied AFTER the page is read, so a scoped
    // list over a table with no index on the owner field returns short pages —
    // correct, but pathological once a caller owns a small fraction of the rows.
    // Warned rather than refused: the resolver does serve the query, and a
    // deployment may legitimately accept the cost on a small table. Mirrors the
    // `@scanSort` alignment warning above, which exists for the same class of
    // "works, but scans" mistake.
    ReventlessCore.OwnerScopeDiagnostics.warnIfNoElevatedGroups(
      ~comp="QueryDbResolvers_AppSync",
      ~view=name,
      ~ownerField,
    )
    switch ownerField {
    | Some(f) =>
      let indexed =
        indexes->Array.some(ic => ic.idField->Option.getOr(ic.index) == f) ||
          subIdField->Option.getOr("") == f
      if !indexed {
        log.warn(
          ~comp="QueryDbResolvers_AppSync",
          `${name}: @owner field "${f}" is not the key of any index on this table. ` ++
          "Owner-scoped reads will Scan and filter, so pages shrink as the caller's " ++
          "share of the rows falls. Add an @index on that field before this read model grows.",
        )
      }
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
          ~requireAttribute?,
          ~ownerField?,
          ~elevatedGroups=Reventless.OwnerScope.elevatedGroups(),
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
        makeQueryResolver(
          ~resolverName,
          ~field=fieldName->Pulumi.Input.make,
          ~code=switch indexConfig.subIdField {
          | Some(sortField) =>
            Resolver.Functions.queryByIndexSortFiltered(~index, ~idField, ~sortField)
          | None => Resolver.Functions.queryByIndexFiltered(~index, ~idField)
          },
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
        // The interceptor leads the chain, as it does in every other Query
        // pipeline. That position means an attempt refused by the row-level index
        // authorization below has still been counted — the same "attempts, not
        // outcomes" bound the hook has everywhere, since it fires before the read
        // and never learns how it ended. Putting it after the auth step would buy
        // outcome-accurate counts and cost the property that matters more: the
        // interceptor is the one place a read can be REFUSED, so it has to be
        // reachable before the pipeline spends a second table read deciding
        // whether this caller may use the index.
        Resolver.makePipelineJsResolver(
          ~name=resolverName,
          ~api,
          ~type_="Query"->Pulumi.Input.make,
          ~field=fieldName->Pulumi.Input.make,
          ~code=Resolver.Functions.pipelinePassThrough,
          ~functions=switch interceptorFunction(~resolverName) {
          | None => [authFunction, queryFunction]
          | Some(interceptorFn) => [interceptorFn, authFunction, queryFunction]
          },
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
