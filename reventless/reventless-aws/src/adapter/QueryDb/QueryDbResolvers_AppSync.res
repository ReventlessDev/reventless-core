open PulumiAws.AppSync
open Reventless.ReadModel

type api = Types.AppSync.api
type role = Types.AppSync.role

type interceptorConfig = {
  dataSourceName: Pulumi.Input.t<string>,
}

/** Deploy-time config for the query interceptor. When set, all top-level Query
    resolvers become pipeline resolvers with an interceptor Lambda function
    preceding the DynamoDB query. Set this before calling `make`. */
let queryInterceptorConfig: ref<option<interceptorConfig>> = ref(None)

let interceptorRequestTemplate = readModelName =>
  `
{
  "version": "2017-02-28",
  "operation": "Invoke",
  "payload": {
    "readModelName": "${readModelName}",
    "arguments": $utils.toJson($context.arguments),
    "identity": {
      "userId": $util.toJson($context.identity.sub),
      "username": $util.toJson($context.identity.username),
      "groups": $util.defaultIfNull($context.identity.claims.get("cognito:groups"), []),
      "claims": $util.toJson($context.identity.claims),
      "provider": "Cognito"
    }
  }
}
`->Pulumi.Input.make

let interceptorResponseTemplate =
  `
#if($ctx.error)
  $util.error($ctx.error.message, $ctx.error.type)
#end
$util.toJson($ctx.result)
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
  ~opts,
) => {
  let dataSourceName = dataSourceName->Pulumi.Output.asInput
  let name = name->String.capitalize
  let registryEntry = ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.get(name)

  // In plugin mode, use plugin-prefixed field names from the registry.
  let fieldNameForSingle = switch registryEntry {
  | Some({singleFieldName}) => singleFieldName
  | None => name->Resolver.Templates.uncapitalize
  }

  // Resolve includeIdParam flag from registry (defaults to true for ReadModels)
  let includeIdParam = switch registryEntry {
  | Some({includeIdParam}) => includeIdParam
  | None => true
  }

  // Creates either a unit resolver (no interceptor) or a pipeline resolver
  // (interceptor Lambda → DynamoDB query) depending on queryInterceptorConfig.
  let makeQueryResolver = (
    ~resolverName,
    ~field,
    ~requestTemplate,
    ~responseTemplate,
  ) =>
    switch queryInterceptorConfig.contents {
    | None =>
      Resolver.makeUnitResolver(
        ~name=resolverName,
        ~api,
        ~dataSourceName,
        ~type_="Query"->Pulumi.Input.make,
        ~field,
        ~requestTemplate,
        ~responseTemplate,
        ~opts,
      )
    | Some({dataSourceName: interceptorDsName}) =>
      let interceptorFn = Function.make(
        ~name=resolverName ++ "Interceptor",
        ~api,
        ~dataSource=interceptorDsName,
        ~requestMappingTemplate=interceptorRequestTemplate(name),
        ~responseMappingTemplate=interceptorResponseTemplate,
        ~opts,
      )
      let queryFn = Function.make(
        ~name=resolverName ++ "Query",
        ~api,
        ~dataSource=dataSourceName,
        ~requestMappingTemplate=requestTemplate,
        ~responseMappingTemplate=responseTemplate,
        ~opts,
      )
      Resolver.makePipelineResolver(
        ~name=resolverName,
        ~api,
        ~type_="Query"->Pulumi.Input.make,
        ~field,
        ~requestTemplate="{}"->Pulumi.Input.make,
        ~responseTemplate=Resolver.Templates.result,
        ~functions=[interceptorFn, queryFn],
        ~opts,
      )
    }

  let resolverByIdSingle = if includeIdParam {
    makeQueryResolver(
      ~resolverName=fieldNameForSingle->String.capitalize,
      ~field=fieldNameForSingle->Pulumi.Input.make,
      ~requestTemplate=switch subIdField {
      | Some(sortField) => Resolver.Templates.queryByIdSort(sortField)
      | None => Resolver.Templates.getItemById
      },
      ~responseTemplate=switch subIdField {
      | Some(_) => Resolver.Templates.firstResult
      | None => Resolver.Templates.result
      },
    )
  } else {
    makeQueryResolver(
      ~resolverName=fieldNameForSingle->String.capitalize,
      ~field=fieldNameForSingle->Pulumi.Input.make,
      ~requestTemplate=Resolver.Templates.listAllItems,
      ~responseTemplate=Resolver.Templates.firstResult,
    )
  }

  let resolverByIdMultiple = if includeIdParam {
    subIdField->Option.map(_sortField =>
      makeQueryResolver(
        ~resolverName=fieldNameForSingle->String.capitalize ++ "ById",
        ~field=(fieldNameForSingle ++ "ById")->Pulumi.Input.make,
        ~requestTemplate=Resolver.Templates.queryById,
        ~responseTemplate=Resolver.Templates.result,
      )
    )
  } else {
    None
  }

  let fieldNameForAll = switch registryEntry {
  | Some({listFieldName}) => listFieldName
  | None => name ++ "s"
  }
  let resolverAll = makeQueryResolver(
    ~resolverName=fieldNameForAll->String.capitalize,
    ~field=fieldNameForAll->Pulumi.Input.make,
    ~requestTemplate=Resolver.Templates.listAllItems,
    ~responseTemplate=Resolver.Templates.result,
  )

  let resourcesMaker: ReventlessCore.QueryDb.resolversResourcesMaker = allQueryDbs => {
    let resolversByIndex = indexes->Array.map(({index} as indexConfig) => {
      let name = name ++ ("By" ++ index->String.capitalize)
      let idField = indexConfig.idField->Option.getOr(index)
      switch indexConfig.authorization {
      | None =>
        Resolver.makeUnitResolver(
          ~name,
          ~api,
          ~dataSourceName,
          ~type_="Query"->Pulumi.Input.make,
          ~field=name->Resolver.Templates.uncapitalize->Pulumi.Input.make,
          ~requestTemplate=switch indexConfig.subIdField {
          | Some(sortField) =>
            Resolver.Templates.queryByIndexSortFiltered(~index, ~idField, ~sortField)
          | None => Resolver.Templates.queryByIndexFiltered(~index, ~idField)
          },
          ~responseTemplate=Resolver.Templates.result,
          ~opts,
        )
      | Some({tableName, group}) =>
        let authDataSource = DataSource.makeDynamoDBDataSourceWithTableName(
          ~name=name ++ "Auth",
          ~api,
          ~tableName=(
            allQueryDbs
            ->ReventlessCore.Util.QueryDb.getLocalStorageResources(tableName)
            ->Util.DynamoDb.findResource
          ).name,
          ~serviceRole=apiRole,
          ~opts,
        )
        let authFunction = Function.make(
          ~name=name ++ "Auth",
          ~api,
          ~dataSource=authDataSource.name->Pulumi.Output.asInput,
          ~requestMappingTemplate=Resolver.Templates.authorizeIndexedAccessRequest(~index, ~group),
          ~responseMappingTemplate=Resolver.Templates.authorizeIndexedAccessResponse(~group),
          ~opts,
        )
        let queryFunction = Function.make(
          ~name,
          ~api,
          ~dataSource=dataSourceName,
          ~requestMappingTemplate=Resolver.Templates.queryByIndexFiltered(~index, ~idField),
          ~responseMappingTemplate=Resolver.Templates.result,
          ~opts,
        )
        Resolver.makePipelineResolver(
          ~name,
          ~api,
          ~type_="Query"->Pulumi.Input.make,
          ~field=name->Resolver.Templates.uncapitalize->Pulumi.Input.make,
          ~requestTemplate="{}"->Pulumi.Input.make,
          ~responseTemplate=Resolver.Templates.result,
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

    let generateTemplate = (~storageResource: ReventlessInfra.Adapter.resource, ~template) =>
      storageResource.name
      ->Pulumi.Output.apply(realTableName => template(realTableName))
      ->Pulumi.Output.asInput

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

        Resolver.makeUnitResolver(
          ~name=name ++ field->String.capitalize,
          ~api,
          ~dataSourceName,
          ~type_=name->Pulumi.Input.make,
          ~field=field->Pulumi.Input.make,
          ~requestTemplate=switch (targetId, sourceSubId, target.subIdField) {
          | (Id, Field(sourceSortField), Some(targetSortField)) =>
            Resolver.Templates.resolveIdSort(~sourceIdField, ~sourceSortField, ~targetSortField)
          | (Id, Argument(sourceSortArgument), Some(targetSortField)) =>
            Resolver.Templates.resolveIdSortArgument(
              ~sourceIdField,
              ~sourceSortArgument,
              ~targetSortField,
            )
          | (Id, _, _) => Resolver.Templates.resolveId(~sourceIdField)

          | (_, Field(sourceSortField), Some(targetSortField)) =>
            Resolver.Templates.resolveIdByIndexSort(
              ~index,
              ~sourceIdField,
              ~targetIdField,
              ~sourceSortField,
              ~targetSortField,
            )
          | (_, Argument(sourceSortArgument), Some(targetSortField)) =>
            Resolver.Templates.resolveIdByIndexSortArgument(
              ~index,
              ~sourceIdField,
              ~targetIdField,
              ~sourceSortArgument,
              ~targetSortField,
            )
          | _ => Resolver.Templates.resolveIdByIndex(~index, ~sourceIdField, ~targetIdField)
          },
          ~responseTemplate=switch resolvedField {
          | Single(_) => Resolver.Templates.firstResult
          | Multi(_) => Resolver.Templates.result
          },
          ~opts,
        )
      }
    })

    let idsResolvers = idsResolverConfigs->Array.map(config => {
      let {source: {idsField, resolvedField}, target: {tableName} as target} = config
      let storageResource = storageResource(~pluginName=target.pluginName, ~tableName)

      Resolver.makeUnitResolver(
        ~name=name ++ idsField->String.capitalize,
        ~api,
        ~dataSourceName,
        ~type_=name->Pulumi.Input.make,
        ~field=resolvedField->Pulumi.Input.make,
        ~requestTemplate=generateTemplate(
          ~storageResource,
          ~template=Resolver.Templates.resolveIds(~idsField, ~sortField=target.subIdField, ...),
        ),
        ~responseTemplate=generateTemplate(
          ~storageResource,
          ~template=Resolver.Templates.resolveIdsResult(~idsField, ...),
        ),
        ~opts,
      )
    })

    Array.flat([resolversByIndex, idResolvers, idsResolvers])->Array.map(Util.AppSync.toResource)
  }

  let resolvers = switch resolverByIdMultiple {
  | Some(resolverByIdMultiple) => [resolverByIdSingle, resolverByIdMultiple, resolverAll]
  | None => [resolverByIdSingle, resolverAll]
  } // TODO add other resolvers (from maker)

  let resources = resolvers->Array.map(Util.AppSync.toResource)

  {resources, resourcesMaker}
}
