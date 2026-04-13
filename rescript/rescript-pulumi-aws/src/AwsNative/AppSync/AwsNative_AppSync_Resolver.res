/** @pulumi/aws-native/appsync/Resolver — Cloud Control API (CFN handler).
    Used instead of @pulumi/aws/appsync/Resolver to avoid the schema ->
    resolver propagation race; the CFN handler waits internally.
    See: https://www.pulumi.com/registry/packages/aws-native/api-docs/appsync/resolver
*/
type t = {
  id: Pulumi.Output.t<string>,
  resolverArn: Pulumi.Output.t<string>,
  typeName: Pulumi.Output.t<string>,
  fieldName: Pulumi.Output.t<string>,
}

type runtime = {
  name: string,
  runtimeVersion: string,
}

/** APPSYNC_JS runtime v1.0.0 — use with `code` instead of VTL templates. */
let appsyncJs: runtime = {name: "APPSYNC_JS", runtimeVersion: "1.0.0"}

type pipelineConfig = {functions: array<Pulumi.Input.t<string>>}

type args = {
  apiId: Pulumi.Input.t<string>,
  typeName: Pulumi.Input.t<string>,
  fieldName: Pulumi.Input.t<string>,
  dataSourceName?: Pulumi.Input.t<string>,
  kind?: Pulumi.Input.t<string>,
  code?: Pulumi.Input.t<string>,
  runtime?: Pulumi.Input.t<runtime>,
  pipelineConfig?: Pulumi.Input.t<pipelineConfig>,
}

@module("@pulumi/aws-native") @scope("appsync") @new
external make: (
  ~name: string,
  ~args: args,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) => t = "Resolver"
