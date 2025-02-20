open PulumiAws.AppSync
open ReventlessSpec.ReadModel_Spec
open Reventless

type api = Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>
type role = Pulumi.Output.t<PulumiAws.IAM.Role.t>

let make: QueryDb.Adapter.resolversMaker<api, role> = (
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
  let name = name->StringLabels.capitalize_ascii
  let resolverByIdSingle = Resolver.makeUnitResolver(
    ~name,
    ~api,
    ~dataSourceName,
    ~type_="Query"->Pulumi.Input.make,
    ~field=name->StringLabels.uncapitalize_ascii->Pulumi.Input.make,
    ~requestTemplate=switch subIdField {
    | Some(sortField) => Resolver.Templates.queryByIdSort(sortField)
    | None => Resolver.Templates.getItemById
    },
    ~responseTemplate=switch subIdField {
    | Some(_) => Resolver.Templates.firstResult
    | None => Resolver.Templates.result
    },
    ~opts,
  )
  let resolverByIdMultiple =
    subIdField->Belt.Option.map(_sortField =>
      Resolver.makeUnitResolver(
        ~name=name ++ "ById",
        ~api,
        ~dataSourceName,
        ~type_="Query"->Pulumi.Input.make,
        ~field=(name->StringLabels.uncapitalize_ascii ++ "ById")->Pulumi.Input.make,
        ~requestTemplate=Resolver.Templates.queryById,
        ~responseTemplate=Resolver.Templates.result,
        ~opts,
      )
    )

  let fieldNameForAll = "every" ++ name
  let resolverAll = Resolver.makeUnitResolver(
    ~name=fieldNameForAll->StringLabels.capitalize_ascii,
    ~api,
    ~dataSourceName,
    ~type_="Query"->Pulumi.Input.make,
    ~field=fieldNameForAll->Pulumi.Input.make,
    ~requestTemplate=Resolver.Templates.listAllItems,
    ~responseTemplate=Resolver.Templates.result,
    ~opts,
  )

  let resourcesMaker: Reventless.QueryDb.resolversResourcesMaker = allQueryDbs => {
    let resolversByIndex = indexes->Belt.Array.map(({index} as indexConfig) => {
      let name = name ++ ("By" ++ index->StringLabels.capitalize_ascii)
      let idField = indexConfig.idField->Belt.Option.getWithDefault(index)
      switch indexConfig.authorization {
      | None =>
        Resolver.makeUnitResolver(
          ~name,
          ~api,
          ~dataSourceName,
          ~type_="Query"->Pulumi.Input.make,
          ~field=name->StringLabels.uncapitalize_ascii->Pulumi.Input.make,
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
            ->Util_QueryDbRuntime.getLocalStorageResources(tableName)
            ->Util_DynamoDb.findResource
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
          ~field=name->StringLabels.uncapitalize_ascii->Pulumi.Input.make,
          ~requestTemplate="{}"->Pulumi.Input.make,
          ~responseTemplate=Resolver.Templates.result,
          ~functions=[authFunction, queryFunction],
          ~opts,
        )
      }
    })

    let storageResource = (~pluginName: option<string>, ~tableName: string) =>
      allQueryDbs
      ->Plugin_Builder.getStorageResources(pluginName, tableName)
      ->Util_DynamoDb.findResourceInOutput
      ->Reventless.Adapter.outputToResource

    let generateTemplate = (~storageResource: ReventlessSpec.Adapter.resource, ~template) =>
      storageResource.name
      ->Pulumi.Output.apply(realTableName => template(realTableName))
      ->Pulumi.Output.asInput

    let idResolvers = idResolverConfigs->Belt.Array.map(config => {
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
            ~name=name ++ (field->StringLabels.capitalize_ascii ++ "Resolver"),
            ~api,
            ~tableName=storageResource.name,
            ~serviceRole=apiRole,
            ~opts,
          ).name->Pulumi.Output.asInput

        Resolver.makeUnitResolver(
          ~name=name ++ field->StringLabels.capitalize_ascii,
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

    let idsResolvers = idsResolverConfigs->Belt.Array.map(config => {
      let {source: {idsField, resolvedField}, target: {tableName} as target} = config
      let storageResource = storageResource(~pluginName=target.pluginName, ~tableName)

      Resolver.makeUnitResolver(
        ~name=name ++ idsField->StringLabels.capitalize_ascii,
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

    Belt.Array.concatMany([resolversByIndex, idResolvers, idsResolvers])->Belt.Array.map(
      Util_AppSync.toResource,
    )
  }

  let resolvers = switch resolverByIdMultiple {
  | Some(resolverByIdMultiple) => [resolverByIdSingle, resolverByIdMultiple, resolverAll]
  | None => [resolverByIdSingle, resolverAll]
  } // TODO add other resolvers (from maker)

  let resources = resolvers->Belt.Array.map(Util_AppSync.toResource)

  {resources, resourcesMaker}
}
