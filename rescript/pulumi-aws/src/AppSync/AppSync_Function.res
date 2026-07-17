/** @pulumi/aws/appsync/Function
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/function
*/
type t = {
  id: Pulumi.Output.t<string>,
  functionId: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type runtime = {
  name: string,
  runtimeVersion: string,
}

/** APPSYNC_JS runtime v1.0.0 — use with `code` instead of VTL templates. */
let appsyncJs: runtime = {name: "APPSYNC_JS", runtimeVersion: "1.0.0"}

type args = {
  apiId: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  dataSource: Pulumi.Input.t<string>,
  requestMappingTemplate?: Pulumi.Input.t<string>,
  responseMappingTemplate?: Pulumi.Input.t<string>,
  /** Bundled JS function code (APPSYNC_JS runtime). Replaces requestMappingTemplate/responseMappingTemplate. */
  code?: Pulumi.Input.t<string>,
  /** Runtime config — set to appsyncJs when using code. */
  runtime?: Pulumi.Input.t<runtime>,
}

@module("@pulumi/aws") @scope("appsync") @new
external _make: (~name: string, ~args: args, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "Function"

let make = (
  ~name,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~dataSource,
  ~requestMappingTemplate,
  ~responseMappingTemplate,
  ~opts=?,
) =>
  _make(
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

/** Create a pipeline function using the APPSYNC_JS runtime.
    Pass bundled JS code via `~code` instead of VTL mapping templates. */
let makeJs = (
  ~name,
  ~api: Pulumi.Output.t<AppSync_GraphQLApi.t>,
  ~dataSource,
  ~code: Pulumi.Input.t<string>,
  ~opts=?,
) =>
  _make(
    ~name,
    ~args={
      name: name->Pulumi.Input.make, // This has to be provided for AppSync.Function
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      dataSource,
      code,
      runtime: appsyncJs->Pulumi.Input.make,
    },
    ~opts,
  )
