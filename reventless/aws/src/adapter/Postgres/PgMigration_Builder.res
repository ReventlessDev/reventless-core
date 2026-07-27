// Deploy-time builder for the one-shot Postgres schema migration (A3).
//
// Provisions an in-VPC Lambda whose only job is to run `PgSchema.ensureSchema`
// against the freshly-provisioned RDS instance, and an `aws.lambda.Invocation`
// resource that invokes it once during `pulumi up`. Because the invocation runs
// the Lambda *inside* the DB's VPC, the deploy runner itself needs no network
// path to the private instance — the reason the plan (A3) chose a migration
// Lambda over a Pulumi `command`/dynamic resource that would have to connect
// from the runner.
//
// `PgConnection.make` calls this after creating the instance so every
// `PgConnection` provisions its own schema; the returned resources are appended
// to `PgConnection.t.resources` so the B-phase storage adapters order after the
// migration. `ensureSchema` is idempotent (all `IF NOT EXISTS`), so the
// invocation re-runs safely whenever the migration code or the Reventless Lambda
// layer (which ships the DDL) changes.

// Takes the connection as already-serialized pieces rather than the
// `PgConnection.connectionConfig` record: `PgConnection` calls this builder, so
// referencing its type here would form a module cycle. The caller passes:
//   ~handlerConfig — the full HANDLER_CONFIG JSON (`{"pgConnection":{…}}`),
//   ~secretArn     — the DB's RDS-managed master secret ARN (for the IAM grant).
// ~securityGroupId: DB-access SG the migration Lambda attaches (PgConnection.securityGroupId).
// ~subnetIds: private subnets for the in-VPC migration Lambda (PgConnection.subnetIds).
let make = (
  ~name: string,
  ~handlerConfig: Pulumi.Output.t<string>,
  ~secretArn: Pulumi.Output.t<string>,
  ~securityGroupId: Pulumi.Output.t<string>,
  ~subnetIds: array<Pulumi.Input.t<string>>,
  ~opts: option<Pulumi.ComponentResource.options>=?,
): array<ReventlessInfra.Adapter.resource> => {
  open PulumiAws

  let {code, sourceCodeHash} = Util_Bundle.buildCodeArchive(
    ~entryPointModule="@reventlessdev/reventless-aws/src/adapter/Runtime/PgMigrationEntryPoint.res.mjs",
    ~packageDirs=Dict.make(),
  )

  let envVars = Dict.fromArray([("HANDLER_CONFIG", handlerConfig->Pulumi.Output.asInput)])

  let vpcConfig =
    securityGroupId
    ->Pulumi.Output.apply(sgId =>
      (
        {
          Lambda.Function.subnetIds: subnetIds->Pulumi.Input.make,
          securityGroupIds: [sgId->Pulumi.Input.make]->Pulumi.Input.make,
        }: Lambda.Function.vpcConfig
      )
    )
    ->Pulumi.Output.asInput

  let runtime = RuntimeEnvironment_Lambda.makeFromCodeAsset(
    ~name,
    ~unitKind=ReventlessCore.Monitoring.Other("Migration"),
    ~componentKind=ReventlessCore.ComponentType.Platform,
    ~code,
    ~sourceCodeHash,
    ~envVars,
    ~vpcConfig,
    ~opts?,
  )

  // IAM: GetSecretValue on the DB's RDS-managed master secret. Built outside an
  // Output.apply so the RolePolicy is a top-level resource the invocation can
  // `dependsOn` (invoke only after the Lambda can read the secret).
  let rolePolicy = {
    open PulumiAws.PolicyDocument
    IAM.RolePolicy.make(
      ~name=`${name}MigrationAccess`,
      ~args={
        policy: secretArn
        ->Pulumi.Output.apply(arn =>
          PulumiAws.PolicyDocument.make(
            ~id=`${name}MigrationAccessPolicy`,
            ~statements=[
              {
                sid: "AllowGetSecret",
                effect: Allow,
                actions: Action("secretsmanager:GetSecretValue"),
                resources: Resource(arn),
              },
            ],
          )->PulumiAws.PolicyDocument.toJsonString
        )
        ->Pulumi.Output.asInput,
        role: runtime.parts.lambdaRole.id->Pulumi.Output.asInput,
      },
    )
  }

  // Re-invoke whenever the migration code or the Reventless layer (which ships
  // PgSchema's DDL) changes; idempotent DDL makes an unchanged re-run a no-op.
  let layerArn = PulumiAws.Lambda.reventlessLayerArn->Option.getOr("no-layer")
  let inputJson =
    [("trigger", `${sourceCodeHash}:${layerArn}`->JSON.Encode.string)]
    ->Dict.fromArray
    ->JSON.Encode.object
    ->JSON.stringify

  let invocation = Lambda.Invocation.make(
    ~name=`${name}Migrate`,
    ~args={
      // Ordering: functionName ties to the Lambda, whose env depends on
      // connectionConfig (the instance's resolved outputs), so the invocation
      // waits for the DB to be available. dependsOn adds the secret-access policy.
      functionName: runtime.parts.lambda->Pulumi.Output.flatMap(l => l.name)->Pulumi.Output.asInput,
      input: inputJson->Pulumi.Input.make,
    },
    ~opts={
      dependsOn: [rolePolicy->Pulumi.Resource.makeFromJs]->Pulumi.Input.make,
    },
  )

  Array.concat(
    runtime.resources,
    [
      ReventlessInfra.Adapter.make(
        ~name=`${name}Migration`->Pulumi.Output.make,
        ~id=invocation.id,
        ~urn=invocation.id,
        ~service="aws:lambda"->Pulumi.Output.make,
        ~role="postgres-migration"->Pulumi.Output.make,
        ~resourceType="aws:lambda:Invocation"->Pulumi.Output.make,
      ),
    ],
  )
}
