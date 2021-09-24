open PulumiAws.AppSync;
open Reventless;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: QueryDb.Adapter.resolversMaker(api, role) =
  (
    ~name: string,
    ~api: api,
    ~apiRole: role,
    ~dataSourceName,
    ~indexes: list(View.index),
    ~sortField,
    ~resolveIdConfigs: list(View.resolveIdConfig), // TODO: use array instead!!!
    ~resolveIdsConfigs: list(View.resolveIdsConfig), // TODO: use array instead!!!
    ~opts,
  ) => {
    open Resolver.Templates;
    let dataSourceName = dataSourceName->Pulumi.Output.asInput;
    let name = name->String.capitalize;
    let resolverById =
      Resolver.make(
        ~name,
        ~api,
        ~dataSourceName,
        ~_type="Query"->Pulumi.Input.wrap,
        ~field=name->String.uncapitalize->Pulumi.Input.wrap,
        ~requestTemplate=
          sortField
          ->(
              fun
              | Some(sortField) => queryByIdSort(sortField)
              | None => getItemById
            )
          ->Pulumi.Input.wrap,
        ~responseTemplate=
          sortField
          ->(
              fun
              | Some(_) => firstResult
              | None => result
            )
          ->Pulumi.Input.wrap,
        ~kind=Unit,
        ~opts,
        (),
      )
      ->Util_AppSync.toResource;

    let fieldNameForAll = "every" ++ name;
    let resolverAll =
      Resolver.make(
        ~name=fieldNameForAll->String.capitalize,
        ~api,
        ~dataSourceName,
        ~_type="Query"->Pulumi.Input.wrap,
        ~field=fieldNameForAll->Pulumi.Input.wrap,
        ~requestTemplate=listAllItems->Pulumi.Input.wrap,
        ~responseTemplate=result->Pulumi.Input.wrap,
        ~kind=Unit,
        ~opts,
        (),
      )
      ->Util_AppSync.toResource;

    let resolversByIndex =
      indexes->Belt.List.map(({View.index, authorization}) => {
        let name = name ++ "By" ++ index->String.capitalize;
        (
          switch (authorization) {
          | None =>
            Resolver.make(
              ~name,
              ~api,
              ~dataSourceName,
              ~_type="Query"->Pulumi.Input.wrap,
              ~field=name->String.uncapitalize->Pulumi.Input.wrap,
              ~requestTemplate=queryByIndexFiltered(index)->Pulumi.Input.wrap,
              ~responseTemplate=result->Pulumi.Input.wrap,
              ~kind=Unit,
              ~opts,
              (),
            )
          | Some({tableName, group}) =>
            let authDataSource =
              DataSource.makeDynamoDBDataSourceWithTableName(
                ~name=name ++ "Auth",
                ~api,
                ~tableName=
                  Util_QueryDb.Deploytime.getStorageResource(tableName)##name,
                ~serviceRole=apiRole,
                ~opts,
                (),
              );
            let authFunction =
              Function.make(
                ~name=name ++ "Auth",
                ~api,
                ~dataSource=authDataSource##name->Pulumi.Output.asInput,
                ~requestMappingTemplate=
                  authorizeIndexedAccessRequest(~index, ~group)
                  ->Pulumi.Input.wrap,
                ~responseMappingTemplate=
                  authorizeIndexedAccessResponse(~group)->Pulumi.Input.wrap,
                ~opts,
                (),
              );
            let queryFunction =
              Function.make(
                ~name,
                ~api,
                ~dataSource=dataSourceName,
                ~requestMappingTemplate=
                  queryByIndexFiltered(index)->Pulumi.Input.wrap,
                ~responseMappingTemplate=result->Pulumi.Input.wrap,
                ~opts,
                (),
              );
            Resolver.make(
              ~name,
              ~api,
              ~_type="Query"->Pulumi.Input.wrap,
              ~field=name->String.uncapitalize->Pulumi.Input.wrap,
              ~requestTemplate="{}"->Pulumi.Input.wrap,
              ~responseTemplate=result->Pulumi.Input.wrap,
              ~kind=Pipeline([|authFunction, queryFunction|]),
              ~opts,
              (),
            );
          }
        )
        ->Util_AppSync.toResource;
      });

    let generateTemplate:
      (~tableName: string, ~template: string => string) =>
      Pulumi.Input.t(string) =
      (~tableName, ~template) =>
        Util_QueryDb.Deploytime.getStorageResourceOutput(tableName)
        ->Pulumi.Output.flatMap(storageResource => storageResource##name)
        ->Pulumi.Output.apply(realTableName => template(realTableName))
        ->Pulumi.Output.asInput;

    let idResolvers =
      resolveIdConfigs->Belt.List.map(config => {
        let {View.idFieldName, fieldName, tableName, index} = config;
        (
          switch (index) {
          | None =>
            Resolver.make(
              ~name=name ++ idFieldName->String.capitalize,
              ~api,
              ~dataSourceName,
              ~_type=name->Pulumi.Input.wrap,
              ~field=fieldName->Pulumi.Input.wrap,
              ~requestTemplate=
                generateTemplate(
                  ~tableName,
                  ~template=resolveId(~idFieldName),
                ),
              ~responseTemplate=
                generateTemplate(
                  ~tableName,
                  ~template=resolveIdResult(~idFieldName),
                ),
              ~kind=Unit,
              ~opts,
              (),
            )
          | Some(index) =>
            let resolverDataSource =
              DataSource.makeDynamoDBDataSourceWithTableName(
                ~name=name ++ idFieldName->String.capitalize ++ "Resolver",
                ~api,
                ~tableName=
                  Util_QueryDb.Deploytime.getStorageResource(tableName)##name,
                ~serviceRole=apiRole,
                ~opts,
                (),
              );
            Resolver.make(
              ~name=name ++ idFieldName->String.capitalize,
              ~api,
              ~dataSourceName=resolverDataSource##name->Pulumi.Output.asInput,
              ~_type=name->Pulumi.Input.wrap,
              ~field=fieldName->Pulumi.Input.wrap,
              ~requestTemplate=
                resolveIdByIndex(~idFieldName, ~index)->Pulumi.Input.wrap,
              ~responseTemplate=firstResult->Pulumi.Input.wrap,
              ~kind=Unit,
              ~opts,
              (),
            );
          }
        )
        ->Util_AppSync.toResource;
      });

    let idsResolvers =
      resolveIdsConfigs->Belt.List.map(config => {
        let {View.fieldName, tableName, idsFieldName, sortField} = config;
        Resolver.make(
          ~name=name ++ idsFieldName->String.capitalize,
          ~api,
          ~dataSourceName,
          ~_type=name->Pulumi.Input.wrap,
          ~field=fieldName->Pulumi.Input.wrap,
          ~requestTemplate=
            generateTemplate(
              ~tableName,
              ~template=resolveIds(~idsFieldName, ~sortField),
            ),
          ~responseTemplate=
            generateTemplate(
              ~tableName,
              ~template=resolveIdsResult(~idsFieldName),
            ),
          ~kind=Unit,
          ~opts,
          (),
        )
        ->Util_AppSync.toResource;
      });

    let singleResolverResources = [|resolverById, resolverAll|]; // TODO add other resolvers (from maker)
    let resolverResources =
      Belt.Array.concatMany([|
        singleResolverResources,
        (resolversByIndex @ idResolvers @ idsResolvers)->Belt.List.toArray,
      |]);

    resolverResources;
  };
