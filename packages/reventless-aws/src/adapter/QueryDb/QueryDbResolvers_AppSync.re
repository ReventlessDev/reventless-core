open PulumiAws.AppSync;
open ReventlessSpec.ReadModelSpec;
open Reventless;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: QueryDb.Adapter.resolversMaker(api, role) =
  (
    ~name: string,
    ~api: api,
    ~apiRole: role,
    ~dataSourceName,
    ~indexes: list(index),
    ~sortField,
    ~resolveIdConfigs: list(resolveIdConfig),
    ~resolveIdsConfigs: list(resolveIdsConfig),
    ~opts,
  ) => {
    open Resolver.Templates;
    let dataSourceName = dataSourceName->Pulumi.Output.asInput;
    let name = name->String.capitalize;
    let resolverByIdSingle =
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
    let resolverByIdMultiple =
      sortField->Belt.Option.map(_sortField =>
        Resolver.make(
          ~name=name ++ "ById",
          ~api,
          ~dataSourceName,
          ~_type="Query"->Pulumi.Input.wrap,
          ~field=(name->String.uncapitalize ++ "ById")->Pulumi.Input.wrap,
          ~requestTemplate=getItemById->Pulumi.Input.wrap,
          ~responseTemplate=result->Pulumi.Input.wrap,
          ~kind=Unit,
          ~opts,
          (),
        )
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
          indexes->Belt.List.map(({index, idField, authorization}) => {
            let name = name ++ "By" ++ index->String.capitalize;
            let idField = idField->Belt.Option.getWithDefault(index);
            switch (authorization) {
            | None =>
              Resolver.make(
                ~name,
                ~api,
                ~dataSourceName,
                ~_type="Query"->Pulumi.Input.wrap,
                ~field=name->String.uncapitalize->Pulumi.Input.wrap,
                ~requestTemplate=
                  queryByIndexFiltered(~index, ~idField)->Pulumi.Input.wrap,
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
                    queryByIndexFiltered(~index, ~idField)->Pulumi.Input.wrap,
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
            (~pluginName: option(string), ~tableName: string) =>
          allQueryDbs
          ->Util_QueryDb.getStorageResources(pluginName, tableName)
          ->Util_DynamoDb.findResourceInOutput;

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
            let {
              idField,
              sortField,
              field,
              pluginName,
              tableName,
              index,
              targetIdField,
              targetSortField,
            }: resolveIdConfig = config;
            let storageResource = storageResource(~pluginName, ~tableName);

            switch (index) {
            | None =>
              Resolver.make(
                ~name=name ++ idField->String.capitalize,
                ~api,
                ~dataSourceName,
                ~_type=name->Pulumi.Input.wrap,
                ~field=field->Pulumi.Input.wrap,
                ~requestTemplate=
                  generateTemplate(
                    ~storageResource,
                    ~template=
                      switch (sortField, targetSortField) {
                      | (Some(sortField), Some(targetSortField)) =>
                        resolveIdSort(~idField, ~sortField, ~targetSortField)
                      | _ => resolveId(~idField)
                      },
                  ),
                ~responseTemplate=
                  generateTemplate(
                    ~storageResource,
                    ~template=
                      switch (sortField, targetSortField) {
                      | (None, Some(_)) => resolveIdResults(~idField)
                      | _ => resolveIdResult(~idField)
                      },
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
                    ~name=name ++ idField->String.capitalize ++ "Resolver",
                    ~api,
                    ~tableName=storageResource##name,
                    ~serviceRole=apiRole,
                    ~opts,
                    (),
                  );
                let targetIdField =
                  targetIdField->Belt.Option.getWithDefault(index);
                Resolver.make(
                  ~name=name ++ idField->String.capitalize,
                  ~api,
                  ~dataSourceName=
                    resolverDataSource##name->Pulumi.Output.asInput,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=field->Pulumi.Input.wrap,
                  ~requestTemplate=
                    switch (sortField, targetSortField) {
                    | (Some(sortField), Some(targetSortField)) =>
                      resolveIdByIndexSort(
                        ~index,
                        ~idField,
                        ~targetIdField,
                        ~sortField,
                        ~targetSortField,
                      )
                      ->Pulumi.Input.wrap
                    | _ =>
                      resolveIdByIndex(~index, ~idField, ~targetIdField)
                      ->Pulumi.Input.wrap
                    },
                  ~responseTemplate=result->Pulumi.Input.wrap,
                  ~kind=Unit,
                  ~opts,
                  (),
                );
              | None =>
                Resolver.make(
                  ~name=name ++ idField->String.capitalize,
                  ~api,
                  ~dataSourceName,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=field->Pulumi.Input.wrap,
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
            let {idsField, field, pluginName, tableName, sortField} = config;
            let storageResource = storageResource(~pluginName, ~tableName);

            Resolver.make(
              ~name=name ++ idsField->String.capitalize,
              ~api,
              ~dataSourceName,
              ~_type=name->Pulumi.Input.wrap,
              ~field=field->Pulumi.Input.wrap,
              ~requestTemplate=
                generateTemplate(
                  ~storageResource,
                  ~template=resolveIds(~idsField, ~sortField),
                ),
              ~responseTemplate=
                generateTemplate(
                  ~storageResource,
                  ~template=resolveIdsResult(~idsField),
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

    let resolvers =
      switch (resolverByIdMultiple) {
      | Some(resolverByIdMultiple) => [|
          resolverByIdSingle,
          resolverByIdMultiple,
          resolverAll,
        |]
      | None => [|resolverByIdSingle, resolverAll|]
      }; // TODO add other resolvers (from maker)

    let resources = resolvers->Belt.Array.map(Util_AppSync.toResource);

    {resources, resourcesMaker};
  };
