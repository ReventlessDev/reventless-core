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
    Js.log2("**********| hello from " ++ __MODULE__ ++ " |*********", dataSourceName)
    open Resolver.Templates;
    let _log = dataSourceName->Pulumi.Output.apply(dsn => Js.log2("QDB-RESOLVER " ++ name ++ "DATASOURCENAME:", dsn))
    let dataSourceName = dataSourceName->Pulumi.Output.asInput;
    let name = name->String.capitalize_ascii;
    let resolverByIdSingle =
      Resolver.make(
        ~name,
        ~api,
        ~dataSourceName,
        ~_type="Query"->Pulumi.Input.make,
        ~field=name->String.uncapitalize_ascii->Pulumi.Input.make,
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
          ~_type="Query"->Pulumi.Input.make,
          ~field=(name->String.uncapitalize_ascii ++ "ById")->Pulumi.Input.make,
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
        ~name=fieldNameForAll->String.capitalize_ascii,
        ~api,
        ~dataSourceName,
        ~_type="Query"->Pulumi.Input.make,
        ~field=fieldNameForAll->Pulumi.Input.make,
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
            ({index, idField, subIdField, authorization}) => {
            let name = name ++ "By" ++ index->String.capitalize_ascii;
            let idField = idField->Belt.Option.getWithDefault(index);
            switch (authorization) {
            | None =>
              Resolver.make(
                ~name,
                ~api,
                ~dataSourceName,
                ~_type="Query"->Pulumi.Input.make,
                ~field=name->String.uncapitalize_ascii->Pulumi.Input.make,
                ~requestTemplate=
                  switch (subIdField) {
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
                ~_type="Query"->Pulumi.Input.make,
                ~field=name->String.uncapitalize_ascii->Pulumi.Input.make,
                ~requestTemplate="{}"->Pulumi.Input.make,
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
                subId: sourceSubId,
                resolvedField,
              },
              target: {
                pluginName,
                tableName,
                idField: targetId,
                subIdField: targetSortField,
              },
            }: resolveIdConfig = config;
            let (index, targetIdField) =
              switch (targetId) {
              | Index(index) => (index, index)
              | IndexWithId(index, targetIdField) => (index, targetIdField)
              | _ => ("", "")
              };
            switch (storageResource(~pluginName, ~tableName), resolvedField) {
            | (Some(storageResource), Single(field))
            | (Some(storageResource), Multi(field)) =>
              let dataSourceName =
                DataSource.makeDynamoDBDataSourceWithTableName(
                  ~name=name ++ field->String.capitalize_ascii ++ "Resolver",
                  ~api,
                  ~tableName=storageResource##name,
                  ~serviceRole=apiRole,
                  ~opts,
                  (),
                )##name
                ->Pulumi.Output.asInput;

              Resolver.make(
                ~name=name ++ field->String.capitalize_ascii,
                ~api,
                ~dataSourceName,
                ~_type=name->Pulumi.Input.make,
                ~field=field->Pulumi.Input.make,
                ~requestTemplate=
                  switch (targetId, sourceSubId, targetSortField) {
                  | (Id, Field(sourceSortField), Some(targetSortField)) =>
                    resolveIdSort(
                      ~sourceIdField,
                      ~sourceSortField,
                      ~targetSortField,
                    )
                  | (
                      Id,
                      Argument(sourceSortArgument),
                      Some(targetSortField),
                    ) =>
                    resolveIdSortArgument(
                      ~sourceIdField,
                      ~sourceSortArgument,
                      ~targetSortField,
                    )
                  | (Id, _, _) => resolveId(~sourceIdField)

                  | (_, Field(sourceSortField), Some(targetSortField)) =>
                    resolveIdByIndexSort(
                      ~index,
                      ~sourceIdField,
                      ~targetIdField,
                      ~sourceSortField,
                      ~targetSortField,
                    )
                  | (_, Argument(sourceSortArgument), Some(targetSortField)) =>
                    resolveIdByIndexSortArgument(
                      ~index,
                      ~sourceIdField,
                      ~targetIdField,
                      ~sourceSortArgument,
                      ~targetSortField,
                    )
                  | _ =>
                    resolveIdByIndex(~index, ~sourceIdField, ~targetIdField)
                  },
                ~responseTemplate=
                  switch (resolvedField) {
                  | Single(_) => firstResult
                  | Multi(_) => result
                  },
                ~kind=Unit,
                ~opts,
                (),
              );
            | (None, Single(field))
            | (None, Multi(field)) =>
              Resolver.make(
                ~name=name ++ field->String.capitalize_ascii,
                ~api,
                ~dataSourceName,
                ~_type=name->Pulumi.Input.make,
                ~field=field->Pulumi.Input.make,
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
              source: {idsField, resolvedField},
              target: {pluginName, tableName, subIdField: sortField},
            } = config;
            let storageResource = storageResource(~pluginName, ~tableName);

            Resolver.make(
              ~name=name ++ idsField->String.capitalize_ascii,
              ~api,
              ~dataSourceName,
              ~_type=name->Pulumi.Input.make,
              ~field=resolvedField->Pulumi.Input.make,
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
