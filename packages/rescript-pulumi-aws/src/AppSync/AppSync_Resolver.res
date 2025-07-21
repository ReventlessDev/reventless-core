/** @pulumi/aws/appsync/Resolver
  see: https://www.pulumi.com/registry/packages/aws/api-docs/appsync/resolver
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  @as("type") type_: Pulumi.Output.t<string>,
  field: Pulumi.Output.t<string>,
}

module Templates = AppSync_Resolver_Templates

type pipelineConfig = {functions: array<Pulumi.Input.t<string>>}

type kind = UNIT | PIPELINE

type args = {
  apiId: Pulumi.Input.t<string>,
  dataSource?: Pulumi.Input.t<string>,
  field: Pulumi.Input.t<string>,
  requestTemplate: Pulumi.Input.t<string>,
  responseTemplate: Pulumi.Input.t<string>,
  @as("type") type_: Pulumi.Input.t<string>,
  kind?: kind,
  pipelineConfig?: Pulumi.Input.t<pipelineConfig>,
}

@module("@pulumi/aws") @scope("appsync") @new
external make: (~name: string, ~args: args, ~opts: option<Pulumi.CustomResourceOptions.t>=?) => t =
  "Resolver"

/*

type kind =
  | Unit
  | Pipeline(array(AppSync_Function.t));


type kind =
  | Unit
  | Pipeline(array(AppSync_Function.t));
let makeHelper =
    (
      ~name,
      ~api: Pulumi.Output.t(PulumiAws.AppSync_GraphQLApi.t),
      ~dataSourceName,
      ~_type,
      ~field,
      ~requestTemplate,
      ~responseTemplate,
      ~kind,
      ~opts=?,
      _,
    ) => {
  let (kind, pipelineConfig) =
    switch (kind) {
    | Unit => (`UNIT, None)
    | Pipeline(functions) => (
        `PIPELINE,
        Some(
          PipelineConfig.make(
            ~functions=
              functions->Array.map(f =>
                f##functionId->Pulumi.Output.asInput
              ),
          )
          ->Pulumi.Input.make,
        ),
      )
    };

  make(
    ~name,
    ~args=
      Args.make(
        ~apiId=
          api->Pulumi.Output.flatMap(api => api##id)->Pulumi.Output.asInput,
        ~dataSource=dataSourceName,
        ~field,
        ~requestTemplate,
        ~responseTemplate,
        ~kind,
        ~pipelineConfig?,
        ~_type,
        (),
      ),
    ~opts=
      opts->Option.map(opts => {
        let optsWithDelete = Js.Obj.assign(Js.Obj.empty(), opts);
        optsWithDelete##deleteBeforeReplace #= Some(true);
        optsWithDelete;
      }),
  );
};
*/

let makeUnitResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync_GraphQLApi.t>,
  ~dataSourceName,
  ~type_,
  ~field,
  ~requestTemplate,
  ~responseTemplate,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  make(
    ~name,
    ~args={
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      dataSource: dataSourceName,
      field,
      requestTemplate,
      responseTemplate,
      kind: UNIT,
      type_,
    },
    ~opts=opts->Option.map(opts => {
      ...opts,
      deleteBeforeReplace: true,
    }),
  )

let makePipelineResolver = (
  ~name,
  ~api: Pulumi.Output.t<PulumiAws.AppSync_GraphQLApi.t>,
  ~type_,
  ~field,
  ~requestTemplate,
  ~responseTemplate,
  ~functions: array<AppSync_Function.t>,
  ~opts: option<Pulumi.CustomResourceOptions.t>=?,
) =>
  make(
    ~name,
    ~args={
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      field,
      requestTemplate,
      responseTemplate,
      kind: PIPELINE,
      pipelineConfig: {
        functions: functions->Array.map(f => f.functionId->Pulumi.Output.asInput),
      }->Pulumi.Input.make,
      type_,
    },
    ~opts=opts->Option.map(opts => {
      ...opts,
      deleteBeforeReplace: true,
    }),
  )
