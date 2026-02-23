/** @pulumi/aws/appsync/Function
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/function
*/
type t = {
  id: Pulumi.Output.t<string>,
  functionId: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type args = {
  apiId: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  dataSource: Pulumi.Input.t<string>,
  requestMappingTemplate: Pulumi.Input.t<string>,
  responseMappingTemplate: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (~name: string, ~args: args, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "Function"

let make = (
  ~name,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~dataSource,
  ~requestMappingTemplate,
  ~responseMappingTemplate,
  ~opts=?,
) =>
  make(
    ~name,
    ~args={
      name: name->Pulumi.Input.make, // This has to be provided for AppSync.Function
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      dataSource,
      requestMappingTemplate,
      responseMappingTemplate,
    },
    ~opts,
  )
