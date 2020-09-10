open PulumiAws.AppSync;
open Reventless;

type api = Pulumi.Output.t(PulumiAws.AppSync.GraphQLApi.t);
type role = Pulumi.Output.t(PulumiAws.IAM.Role.t);

let make: QueryDb.resolversMaker(api, role) =
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
      queryQueryDb => {
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
            | Some(group) =>
              let authDataSource =
                DataSource.makeDynamoDBDataSourceWithTableName(
                  ~name=name ++ "Auth",
                  ~api,
                  ~tableName=
                    queryQueryDb(group)
                    ->Pulumi.Output.flatMap(qdb => qdb##name),
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
                    authorizeIndexedAccessResponse(index)->Pulumi.Input.wrap,
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

        let generateTemplate:
          (~tableName: string, ~template: string => string) =>
          Pulumi.Input.t(string) =
          (~tableName, ~template) =>
            queryQueryDb(tableName)
            ->Pulumi.Output.flatMap(qdb => qdb##name)
            ->Pulumi.Output.apply(realTableName => template(realTableName))
            ->Pulumi.Output.asInput;

        let idResolvers =
          resolveIdConfigs->Belt.List.map(config => {
            let {View.fieldName, tableName, idFieldName} = config;

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
                generateTemplate(~tableName, ~template=resolveIdResult),
              ~kind=Unit,
              ~opts,
              (),
            );
          });
        let idsResolvers =
          resolveIdsConfigs->Belt.List.map(config => {
            let {View.fieldName, tableName, idsFieldName} = config;
            Resolver.make(
              ~name=name ++ idsFieldName->String.capitalize,
              ~api,
              ~dataSourceName,
              ~_type=name->Pulumi.Input.wrap,
              ~field=fieldName->Pulumi.Input.wrap,
              ~requestTemplate=
                generateTemplate(
                  ~tableName,
                  ~template=resolveIds(~idsFieldName),
                ),
              ~responseTemplate=
                generateTemplate(~tableName, ~template=resolveIdsResult),
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

    {QueryDb.resources, resourcesMaker};
  };
