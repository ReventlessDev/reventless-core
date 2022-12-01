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
    ~resolveIdConfigs: list(View.resolveIdConfig),
    ~resolveIdsConfigs: list(View.resolveIdsConfig),
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
      );

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
      );

    let resourcesMaker: QueryDb.resolversResourcesMaker =
      allQueryDbs => {
        let resolversByIndex =
          indexes->Belt.List.map(({View.index, authorization}) => {
            let name = name ++ "By" ++ index->String.capitalize;
            switch (authorization) {
            | None =>
              Resolver.make(
                ~name,
                ~api,
                ~dataSourceName,
                ~_type="Query"->Pulumi.Input.wrap,
                ~field=name->String.uncapitalize->Pulumi.Input.wrap,
                ~requestTemplate=
                  queryByIndexFiltered(index)->Pulumi.Input.wrap,
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
                    allQueryDbs
                    ->Util_QueryDbRuntime.getLocalStorageResources(tableName)
                    ->Util_DynamoDb.findResource##name,
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
            };
          });

        let storageResource =
            (~pluginName: option(string), ~tableName: string) => {
          let resources =
            allQueryDbs->Util_QueryDb.getStorageResources(
              pluginName,
              tableName,
            );
          Js.log2(
            "QueryDbResolvers_AppSync.storageResource: resources:",
            resources,
          );
          resources->Util_DynamoDb.findResourceInOutput;
        };

        let generateTemplate:
          (
            ~storageResource: option(ReventlessSpec.Adapter.resource),
            ~template: string => string
          ) =>
          Pulumi.Input.t(string) =
          (~storageResource, ~template) =>
            switch (storageResource) {
            | Some(storageResource) =>
              storageResource##name
              ->Pulumi.Output.apply(realTableName => template(realTableName))
              ->Pulumi.Output.asInput
            | None => null->Pulumi.Input.wrap
            };

        let idResolvers =
          resolveIdConfigs->Belt.List.map(config => {
            let {View.idFieldName, fieldName, pluginName, tableName, index} = config;
            let storageResource = storageResource(~pluginName, ~tableName);

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
                    ~storageResource,
                    ~template=resolveId(~idFieldName),
                  ),
                ~responseTemplate=
                  generateTemplate(
                    ~storageResource,
                    ~template=resolveIdResult(~idFieldName),
                  ),
                ~kind=Unit,
                ~opts,
                (),
              )
            | Some(index) =>
              switch (storageResource) {
              | Some(storageResource) =>
                let resolverDataSource =
                  DataSource.makeDynamoDBDataSourceWithTableName(
                    ~name=name ++ idFieldName->String.capitalize ++ "Resolver",
                    ~api,
                    ~tableName=storageResource##name,
                    ~serviceRole=apiRole,
                    ~opts,
                    (),
                  );
                Resolver.make(
                  ~name=name ++ idFieldName->String.capitalize,
                  ~api,
                  ~dataSourceName=
                    resolverDataSource##name->Pulumi.Output.asInput,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=fieldName->Pulumi.Input.wrap,
                  ~requestTemplate=
                    resolveIdByIndex(~idFieldName, ~index)->Pulumi.Input.wrap,
                  ~responseTemplate=firstResult->Pulumi.Input.wrap,
                  ~kind=Unit,
                  ~opts,
                  (),
                );
              | None =>
                Resolver.make(
                  ~name=name ++ idFieldName->String.capitalize,
                  ~api,
                  ~dataSourceName,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=fieldName->Pulumi.Input.wrap,
                  ~requestTemplate=null->Pulumi.Input.wrap,
                  ~responseTemplate=null->Pulumi.Input.wrap,
                  ~kind=Unit,
                  ~opts,
                  (),
                )
              }
            };
          });

        let idsResolvers =
          resolveIdsConfigs->Belt.List.map(config => {
            let {
              View.idsFieldName,
              fieldName,
              pluginName,
              tableName,
              sortField,
            } = config;
            let storageResource = storageResource(~pluginName, ~tableName);

            Resolver.make(
              ~name=name ++ idsFieldName->String.capitalize,
              ~api,
              ~dataSourceName,
              ~_type=name->Pulumi.Input.wrap,
              ~field=fieldName->Pulumi.Input.wrap,
              ~requestTemplate=
                generateTemplate(
                  ~storageResource,
                  ~template=resolveIds(~idsFieldName, ~sortField),
                ),
              ~responseTemplate=
                generateTemplate(
                  ~storageResource,
                  ~template=resolveIdsResult(~idsFieldName),
                ),
              ~kind=Unit,
              ~opts,
              (),
            );
          });

        (resolversByIndex @ idResolvers @ idsResolvers)
        ->Belt.List.toArray
        ->Belt.Array.map(Util_AppSync.toResource);
      };

    let resolvers = [|resolverById, resolverAll|]; // TODO add other resolvers (from maker)

    let resources = resolvers->Belt.Array.map(Util_AppSync.toResource);

    {resources, resourcesMaker};
  };
