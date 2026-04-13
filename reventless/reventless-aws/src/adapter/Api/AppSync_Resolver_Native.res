/** AppSync_Resolver_Native — drop-in replacement for
    `PulumiAws.AppSync.Resolver` that uses `@pulumi/aws-native` (Cloud Control
    API) so the CFN handler can internally wait out schema -> resolver
    propagation. See docs/plans/appsync-resolver-aws-native.md. */

module Native = PulumiAws.AwsNative.AppSync.Resolver
module Functions = PulumiAws.AppSync.Resolver.Functions

type t = Native.t

let makeUnitJsResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  ~dataSourceName,
  ~type_,
  ~field,
  ~code,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  Native.make(
    ~name,
    ~args={
      apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
      typeName: type_,
      fieldName: field,
      dataSourceName,
      kind: "UNIT"->Pulumi.Input.make,
      code,
      runtime: Native.appsyncJs->Pulumi.Input.make,
    },
    ~opts=opts,
  )

let makePipelineJsResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  ~type_,
  ~field,
  ~code,
  ~functions: array<PulumiAws.AppSync.Function.t>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  Native.make(
    ~name,
    ~args={
      apiId: api->Pulumi.Output.flatMap(a => a.id)->Pulumi.Output.asInput,
      typeName: type_,
      fieldName: field,
      kind: "PIPELINE"->Pulumi.Input.make,
      code,
      runtime: Native.appsyncJs->Pulumi.Input.make,
      pipelineConfig: (
        {
          functions: functions->Array.map(f => f.functionId->Pulumi.Output.asInput),
        }: Native.pipelineConfig
      )->Pulumi.Input.make,
    },
    ~opts=opts,
  )
