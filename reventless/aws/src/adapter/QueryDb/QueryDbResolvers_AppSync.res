open PulumiAws.AppSync
// Shadow PulumiAws.AppSync.Resolver with the retrying dynamic-provider adapter
// so resolver creation calls the AppSync SDK directly and retries
// `NotFoundException: No field named X` (the schema-propagation race) with
// exponential backoff. Replaces AppSync_Resolver_Native (aws-native provider)
// which exhibited the same race in production.
// See docs/plans/done/appsync-resolver-aws-native-retry.md.
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
    See docs/plans/done/platform-plugins-admin-connection-null-rows.md. */
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
  // AWS path enforces authorization via `@aws_cognito_user_pools(cognito_groups: …)` on the
  // SDL fields (see Stage E in docs/plans/done/host-ui-login-core.md). Accepted but
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
    // The state's `@owner` field, derived from the same schema `capability` is
    // derived from, so the two cannot disagree about this read model's fields.
    //
    // Read HERE, at the top, rather than beside the list resolver that first
    // needed it. The by-id resolvers are built a few lines below and the lookup
    // used to sit well after them, so they were generated without it: a list
    // narrowed to the caller beside a by-id read that hands over any row it is
    // asked for. That is not a partial delivery — the row is reachable by
    // anyone who can name one, and the list gives no sign of it, because the
    // list is correct.
    let stateSchemaOpt = ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.get(name)
    let ownerField = switch stateSchemaOpt {
    | Some(s) => Reventless.Owner.fieldNames(s)->Array.get(0)
    | None => None
    }
    let elevatedGroups = Reventless.OwnerScope.elevatedGroups()

    // Read here for exactly the reason `ownerField` above is, and after making
    // the same mistake: the by-id, by-ids and by-index resolvers are built below
    // and this lookup used to sit past all of them, so they were generated
    // without a retirement predicate — a list that withheld archived rows beside
    // by-key doors that handed any one of them over on request.
    let retiredSpec =
      stateSchemaOpt
      ->Option.flatMap(Reventless.StateAnnotations.getSpec)
      ->Option.flatMap(spec => spec.retired)
    let retiredField = retiredSpec->Option.map(r => r.field)
    let retiredValues = retiredSpec->Option.flatMap(r => r.values)

    let resolverByIdSingle = if includeIdParam {
      makeQueryResolver(
        ~resolverName=fieldNameForSingle->String.capitalize,
        ~field=fieldNameForSingle->Pulumi.Input.make,
        ~code=switch subIdField {
        | Some(sortField) =>
          Resolver.Functions.queryByIdSort(
            sortField,
            ~ownerField?,
            ~elevatedGroups,
            ~retiredField?,
            ~retiredValues?,
          )
        | None =>
          Resolver.Functions.getItemById(
            ~ownerField?,
            ~elevatedGroups,
            ~retiredField?,
            ~retiredValues?,
          )
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
          ~code=Resolver.Functions.queryItemsWithSortConditions(
            sortField,
            ~ownerField?,
            ~elevatedGroups,
          ),
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
    // See docs/plans/done/platform-plugins-admin-connection-null-rows.md.
    let requireAttribute = internalRowRequiredAttr(name)
    ReventlessCore.OwnerScopeDiagnostics.warnIfNoElevatedGroups(
      ~comp="QueryDbResolvers_AppSync",
      ~view=name,
      ~ownerField,
    )
    let isIndexed = f =>
      indexes->Array.some(ic => ic.idField->Option.getOr(ic.index) == f) ||
        subIdField->Option.getOr("") == f
    // The index `@owner` derives, and the sort key that orders one caller's rows
    // inside it. Its absence means the author declined it — the list then falls
    // back to the Scan-and-filter this used to prescribe an `@index` for.
    let ownerIndexConfig = switch ownerField {
    | Some(f) =>
      indexes->Array.find(ic =>
        Reventless.ReadModel.isDerivedIndex(ic) && ic.idField->Option.getOr(ic.index) == f
      )
    | None => None
    }
    let ownerIndex = ownerIndexConfig->Option.map(ic => ic.index)
    let ownerIndexSortField = ownerIndexConfig->Option.flatMap(ic => ic.subIdField)
    // Only reachable through `@owner({index: false})` now that the index is
    // derived by default, so this states the cost of that choice rather than
    // prescribing an `@index` — which would provision a second index on the same
    // key and still not be the one the list reads.
    switch (ownerField, ownerIndex) {
    | (Some(f), None) if !isIndexed(f) =>
      log.warn(
        ~comp="QueryDbResolvers_AppSync",
        `${name}: @owner field "${f}" keys no index on this table, so owner-scoped ` ++
        "reads Scan the table and filter after the page is read — cost grows with the " ++
        "table while the answer shrinks with the caller's share of it. Drop " ++
        "`@owner({index: false})` to let the framework derive the index, or accept " ++
        "the cost on a view that stays small.",
      )
    | _ => ()
    }
    // The same class of "works, but scans" mistake as the owner warning above,
    // and the retirement case degrades the same way: the FilterExpression is
    // applied after the page is read, so pages shrink as the archive's share of
    // the table grows.
    //
    // `@scan` deliberately does not satisfy this. It adds no index and removes
    // no read unit — it only widens the client's filter surface — so accepting it
    // here would make the warning dismissible by an annotation that changes
    // nothing about the cost being warned about.
    switch retiredField {
    | Some(f) =>
      if !isIndexed(f) {
        log.warn(
          ~comp="QueryDbResolvers_AppSync",
          `${name}: @retired field "${f}" is not the key of any index on this table. ` ++
          "Reads that exclude retired rows will Scan and filter, so pages shrink as " ++
          "the archive's share of the rows grows. Add an @index on that field before " ++
          "this read model grows.",
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
          ~elevatedGroups,
          ~retiredField?,
          ~retiredValues?,
          ~ownerIndex?,
          ~ownerIndexSortField?,
        )
      } else {
        Resolver.Functions.listAllItems
      },
    )
    // Derived indexes are absent from the SDL (`GraphQL_FragmentGenerator` skips
    // them), so a resolver here would attach to a field that does not exist and
    // fail the deploy. The list resolver above is the only thing that reads one.
    let resolversByIndex = indexes
    ->Array.filter(ic => !Reventless.ReadModel.isDerivedIndex(ic))
    ->Array.map(({index} as indexConfig) => {
      // Name and key field both come from `GraphQL_FragmentGenerator`, which is
      // where the SDL field this attaches to is derived. Deriving them here as
      // well is how the two came to disagree: the emitted field declared `id`
      // while this resolver read the index key, so the door could not be called.
      let fieldName = ReventlessCore.GraphQL_FragmentGenerator.indexQueryFieldName(
        ~singleFieldName=fieldNameForSingle,
        ~index,
      )
      let resolverName = fieldName->String.capitalize
      let idField = ReventlessCore.GraphQL_FragmentGenerator.indexKeyField(indexConfig)
      switch indexConfig.authorization {
      | None =>
        makeQueryResolver(
          ~resolverName,
          ~field=fieldName->Pulumi.Input.make,
          ~code=switch indexConfig.subIdField {
          | Some(sortField) =>
            Resolver.Functions.queryByIndexSortFiltered(
              ~index,
              ~idField,
              ~sortField,
              ~ownerField?,
              ~retiredField?,
              ~retiredValues?,
              ~elevatedGroups,
            )
          | None =>
            Resolver.Functions.queryByIndexFiltered(
              ~index,
              ~idField,
              ~ownerField?,
              ~retiredField?,
              ~retiredValues?,
              ~elevatedGroups,
            )
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
          // No `~ownerField`, deliberately: this index declares its own
          // authorization, and the rows it grants a group member are by
          // construction owned by somebody else — an order assigned to a
          // fulfilment operator belongs to the customer who placed it. Adding the
          // owner predicate here would return nothing and revoke the access the
          // auth table exists to grant. Retirement still applies: an archived row
          // is withdrawn from everyone who has not asked, whoever owns it.
          ~code=Resolver.Functions.queryByIndexFiltered(
            ~index,
            ~idField,
            ~retiredField?,
            ~retiredValues?,
            ~elevatedGroups,
          ),
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
            ~template=Resolver.Functions.batchGetItemsByIds(
              ~ownerField?,
              ~retiredField?,
              ~retiredValues?,
              ~elevatedGroups,
            ),
          ),
        ),
      )
    } else {
      None
    }

    // The reference door. Registered under the same conditions as by-ids because
    // it is the same read; what differs is the projection on the way out, and
    // that a view which named its retired rows lets them through it.
    //
    // Not conditional on the annotation: `GraphQL_FragmentGenerator` emits the
    // field for every view — one SDL serves every backend — so a view without a
    // resolver here would be a field that errors rather than one that is absent.
    let resolverRefs = if includeIdParam && subIdField === None {
      let storage = storageResource(~pluginName=None, ~tableName=name)
      let refsField = fieldNameForAll ++ "Refs"
      Some(
        makeQueryResolver(
          ~resolverName=refsField->String.capitalize,
          ~field=refsField->Pulumi.Input.make,
          ~code=generateCode(
            ~storageResource=storage,
            ~template=Resolver.Functions.refsByIds(
              ~labelField,
              ~retiredField,
              ~retiredValues,
              ~namedWhenRetired=retiredSpec->Option.mapOr(false, r => r.namedWhenRetired),
              ~ownerField?,
              ~elevatedGroups,
            ),
          ),
        ),
      )
    } else {
      None
    }

    // The GraphQL type the cross-table fields hang off. `name` is the QueryDb's
    // own (capitalised spec) name; the SDL calls the type by its plugin-prefixed
    // name, and a resolver naming the other one is refused at deploy with
    // "No field named X found on type Y".
    let parentTypeName = switch registryEntry {
    | Some({returnTypeName}) => returnTypeName
    | None => name
    }

    // A cross-table field hands back rows from the TARGET's table, so the owner
    // and retirement rules that apply are the target's. Read from the same
    // registry this view reads its own from — populated for every queryable in
    // the plugin before any resolver is built.
    let targetScope = (targetName: string) => {
      let schema = ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.get(targetName)
      let retired =
        schema
        ->Option.flatMap(Reventless.StateAnnotations.getSpec)
        ->Option.flatMap(spec => spec.retired)
      (
        schema->Option.flatMap(s => Reventless.Owner.fieldNames(s)->Array.get(0)),
        retired->Option.map(r => r.field),
        retired->Option.flatMap(r => r.values),
      )
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
      let (targetOwnerField, targetRetiredField, targetRetiredValues) = targetScope(tableName)
      let (field, multi) = switch resolvedField {
      | Single(field) => (field, false)
      | Multi(field) => (field, true)
      }
      let response = Resolver.Functions.resolvedFieldResponse(
        ~multi,
        ~ownerField=targetOwnerField,
        ~elevatedGroups,
        ~retiredField=?targetRetiredField,
        ~retiredValues=?targetRetiredValues,
      )
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
        ~type_=parentTypeName->Pulumi.Input.make,
        ~field=field->Pulumi.Input.make,
        ~code=switch (targetId, sourceSubId, target.subIdField) {
        | (Id, Field(sourceSortField), Some(targetSortField)) =>
          Resolver.Functions.resolveIdSort(
            ~sourceIdField,
            ~sourceSortField,
            ~targetSortField,
            ~response,
          )
        | (Id, Argument(sourceSortArgument), Some(targetSortField)) =>
          Resolver.Functions.resolveIdSortArgument(
            ~sourceIdField,
            ~sourceSortArgument,
            ~targetSortField,
            ~response,
          )
        | (Id, _, _) => Resolver.Functions.resolveId(~sourceIdField, ~response)

        | (_, Field(sourceSortField), Some(targetSortField)) =>
          Resolver.Functions.resolveIdByIndexSort(
            ~index,
            ~sourceIdField,
            ~targetIdField,
            ~sourceSortField,
            ~targetSortField,
            ~response,
          )
        | (_, Argument(sourceSortArgument), Some(targetSortField)) =>
          Resolver.Functions.resolveIdByIndexSortArgument(
            ~index,
            ~sourceIdField,
            ~targetIdField,
            ~sourceSortArgument,
            ~targetSortField,
            ~response,
          )
        | _ =>
          Resolver.Functions.resolveIdByIndex(~index, ~sourceIdField, ~targetIdField, ~response)
        },
        ~opts,
      )
    })

    // `@resolvesMany` — BatchGetItem against the target's table. Runs on THIS
    // view's data source rather than one of the target's: the tables map names
    // the target explicitly, and every QueryDb in the plugin has already granted
    // `dynamodb:*` on itself to the API role the data source assumes.
    let idsResolvers = idsResolverConfigs->Array.map(config => {
      let {source: {idsField, resolvedField}, target: {tableName} as target} = config
      let storageResource = storageResource(~pluginName=target.pluginName, ~tableName)
      let (targetOwnerField, targetRetiredField, targetRetiredValues) = targetScope(tableName)

      Resolver.makeUnitJsResolver(
        ~name=name ++ resolvedField->String.capitalize,
        ~api,
        ~dataSourceName,
        ~type_=parentTypeName->Pulumi.Input.make,
        ~field=resolvedField->Pulumi.Input.make,
        ~code=generateCode(
          ~storageResource,
          ~template=Resolver.Functions.resolveIds(
            ~idsField,
            ~sortField=target.subIdField,
            ~ownerField=?targetOwnerField,
            ~retiredField=?targetRetiredField,
            ~retiredValues=?targetRetiredValues,
            ~elevatedGroups,
          ),
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
    // Appended rather than folded into `mainResolvers`' four-way switch: the door
    // is independent of whether this view has a sub-id door, and adding a third
    // dimension to that match would spell eight cases to say one thing.
    let refsResolvers = resolverRefs->Option.mapOr([], r => [r])
    Array.flat([mainResolvers, refsResolvers, resolversByIndex, idResolvers, idsResolvers])
    ->Array.map(Util.AppSync.toResourceNative)
  }

  {resources: [], resourcesMaker}
}
