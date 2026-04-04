/** @pulumi/aws/appsync/DataSource
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/datasource
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type dynamoDBConfig = {
  tableName: Pulumi.Input.t<string>,
  region?: Pulumi.Input.t<string>,
  useCallerCredentials?: Pulumi.Input.t<bool>,
  opts?: Pulumi.CustomResourceOptions.t,
}

type elasticSearchConfig = {endpoint: Pulumi.Input.t<string>, region?: Pulumi.Input.t<string>}
type httpConfig = {endpoint: Pulumi.Input.t<string>}
type lambdaConfig = {functionArn: Pulumi.Input.t<string>}

type type_ =
  | AWS_LAMBDA
  | AMAZON_DYNAMODB
  | AMAZON_ELASTICSEARCH
  | HTTP
  | NONE

type args = {
  @as("type") type_: type_,
  apiId: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  dynamodbConfig?: dynamoDBConfig,
  elasticsearchConfig?: Pulumi.Input.t<elasticSearchConfig>,
  httpConfig?: Pulumi.Input.t<httpConfig>,
  lambdaConfig?: Pulumi.Input.t<lambdaConfig>,
  serviceRoleArn?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (~name: string, ~args: args=?, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "DataSource"

let makeDynamoDBDataSourceWithTableName: (
  ~name: string,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~tableName: Pulumi.Output.t<string>,
  ~serviceRole: Pulumi.Output.t<IAM.Role.t>,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = (~name, ~api, ~tableName, ~serviceRole, ~opts=?) =>
  make(
    ~name,
    ~args={
      type_: AMAZON_DYNAMODB,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      dynamodbConfig: {
        tableName: tableName->Pulumi.Output.asInput,
      },
      serviceRoleArn: serviceRole
      ->Pulumi.Output.flatMap(role => role.arn)
      ->Pulumi.Output.asInput,
    },
    ~opts=opts->Option.map(opts => {
      ...opts,
      deleteBeforeReplace: true,
    }),
  )

let makeNoneDataSource: (
  ~name: string,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = (~name, ~api, ~opts=?) =>
  make(
    ~name,
    ~args={
      type_: NONE,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
    },
    ~opts=opts->Option.map(opts => {
      ...opts,
      deleteBeforeReplace: true,
    }),
  )

let makeDynamoDBDataSource: (
  ~name: string,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~table: DynamoDb.Table.t,
  ~serviceRole: Pulumi.Output.t<IAM.Role.t>,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = (~name, ~api, ~table, ~serviceRole, ~opts=?) =>
  makeDynamoDBDataSourceWithTableName(~api, ~tableName=table.name, ~name, ~serviceRole, ~opts?)
