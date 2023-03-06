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
    ~subIdField,
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
          switch (subIdField) {
          | Some(sortField) => queryByIdSort(sortField)
          | None => getItemById
          },
        ~responseTemplate=
          switch (subIdField) {
          | Some(_) => firstResult
          | None => result
          },
        ~kind=Unit,
        ~opts,
        (),
      );
    let resolverByIdMultiple =
      subIdField->Belt.Option.map(_sortField =>
        Resolver.make(
          ~name=name ++ "ById",
          ~api,
          ~dataSourceName,
          ~_type="Query"->Pulumi.Input.wrap,
          ~field=(name->String.uncapitalize ++ "ById")->Pulumi.Input.wrap,
          ~requestTemplate=queryById,
          ~responseTemplate=result,
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
        ~requestTemplate=listAllItems,
        ~responseTemplate=result,
        ~kind=Unit,
        ~opts,
        (),
      );

    let resourcesMaker: QueryDb.resolversResourcesMaker =
      allQueryDbs => {
        let resolversByIndex =
          indexes->Belt.List.map(
            ({index, idField, sortField, authorization}) => {
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
                  switch (sortField) {
                  | Some(sortField) =>
                    queryByIndexSortFiltered(~index, ~idField, ~sortField)
                  | None => queryByIndexFiltered(~index, ~idField)
                  },
                ~responseTemplate=result,
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
                    authorizeIndexedAccessRequest(~index, ~group),
                  ~responseMappingTemplate=
                    authorizeIndexedAccessResponse(~group),
                  ~opts,
                  (),
                );
              let queryFunction =
                Function.make(
                  ~name,
                  ~api,
                  ~dataSource=dataSourceName,
                  ~requestMappingTemplate=
                    queryByIndexFiltered(~index, ~idField),
                  ~responseMappingTemplate=result,
                  ~opts,
                  (),
                );
              Resolver.make(
                ~name,
                ~api,
                ~_type="Query"->Pulumi.Input.wrap,
                ~field=name->String.uncapitalize->Pulumi.Input.wrap,
                ~requestTemplate="{}"->Pulumi.Input.wrap,
                ~responseTemplate=result,
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
            | None => null
            };

        let idResolvers =
          resolveIdConfigs->Belt.List.map(config => {
            let {
              source: {
                idField: sourceIdField,
                sortField: sourceSortField,
                field,
              },
              target: {
                pluginName,
                tableName,
                index,
                idField: targetIdField,
                sortField: targetSortField,
                unique,
              },
            }: resolveIdConfig = config;
            switch (storageResource(~pluginName, ~tableName)) {
            | Some(storageResource) =>
              let dataSourceName =
                DataSource.makeDynamoDBDataSourceWithTableName(
                  ~name=name ++ field->String.capitalize ++ "Resolver",
                  ~api,
                  ~tableName=storageResource##name,
                  ~serviceRole=apiRole,
                  ~opts,
                  (),
                )##name
                ->Pulumi.Output.asInput;

              switch (index) {
              | None =>
                Resolver.make(
                  ~name=name ++ field->String.capitalize,
                  ~api,
                  ~dataSourceName,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=field->Pulumi.Input.wrap,
                  ~requestTemplate=
                    switch (sourceSortField, targetSortField) {
                    | (Some(sourceSortField), Some(targetSortField)) =>
                      resolveIdSort(
                        ~sourceIdField,
                        ~sourceSortField,
                        ~targetSortField,
                      )
                    | _ => resolveId(~sourceIdField)
                    },
                  ~responseTemplate=
                    switch (sourceSortField, targetSortField) {
                    | (None, None)
                    | (Some(_), Some(_)) => firstResult
                    | _ => resultList
                    },
                  ~kind=Unit,
                  ~opts,
                  (),
                )
              | Some(index) =>
                let targetIdField =
                  targetIdField->Belt.Option.getWithDefault(index);
                Resolver.make(
                  ~name=name ++ field->String.capitalize,
                  ~api,
                  ~dataSourceName,
                  ~_type=name->Pulumi.Input.wrap,
                  ~field=field->Pulumi.Input.wrap,
                  ~requestTemplate=
                    switch (sourceSortField, targetSortField) {
                    | (Some(sourceSortField), Some(targetSortField)) =>
                      resolveIdByIndexSort(
                        ~index,
                        ~sourceIdField,
                        ~targetIdField,
                        ~sourceSortField,
                        ~targetSortField,
                      )
                    | _ =>
                      resolveIdByIndex(~index, ~sourceIdField, ~targetIdField)
                    },
                  ~responseTemplate=unique ? firstResult : result,
                  ~kind=Unit,
                  ~opts,
                  (),
                );
              };
            | None =>
              Resolver.make(
                ~name=name ++ field->String.capitalize,
                ~api,
                ~dataSourceName,
                ~_type=name->Pulumi.Input.wrap,
                ~field=field->Pulumi.Input.wrap,
                ~requestTemplate=null,
                ~responseTemplate=null,
                ~kind=Unit,
                ~opts,
                (),
              )
            };
          });

        let idsResolvers =
          resolveIdsConfigs->Belt.List.map(config => {
            let {
              source: {idsField, field},
              target: {pluginName, tableName, sortField},
            } = config;
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
