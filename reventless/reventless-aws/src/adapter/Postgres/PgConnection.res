/** Deploy-time component that provisions a managed Postgres instance (RDS) and
  resolves the connection details the `reventless-postgres` runtime needs inside
  a Lambda.

  One `PgConnection` hosts **all three** storage surfaces (classic `event_log`,
  DCB `dcb_event`, and the QueryDb `qdb_*` tables) in a single database — the
  per-surface adapters take a reference to it, they do not each provision a DB.

  Networking is supplied by the platform (an existing VPC + private subnets); a
  `PgConnection` does not provision a VPC. It creates:
  - a **shared security group** with a self-referencing `5432` ingress rule, so
    every Lambda that attaches this same SG (see C1 / `securityGroupId`) can
    reach the DB without a separate client SG;
  - a **DB subnet group** over the given private subnets;
  - the **RDS instance** with `manageMasterUserPassword` — RDS mints and rotates
    the master credentials in Secrets Manager, so no plaintext password ever
    lands in Pulumi state. The resulting secret ARN surfaces on
    `connectionConfig.secretArn`; the runtime resolves it at cold start.

  Aurora / Aurora Serverless v2 is a planned second engine behind the same
  `connectionConfig` output shape (tracked in the AWS-Postgres plan). */

/** Resolved at deploy time, serialized into the handler Lambda env, and consumed
  at cold start to build a `PgDriver` pool. `secretArn` points at the
  RDS-managed `{username, password}` secret; `host`/`port`/`database` come from
  the instance itself. */
@schema
type connectionConfig = {
  host: string,
  port: int,
  database: string,
  /** RDS master username — set at deploy time, not secret. The pool's `user`;
    the Secrets Manager secret supplies only the matching password. */
  username: string,
  secretArn: string,
}

/** Serialize a resolved `connectionConfig` into the `pgConnection` JSON object
  the runtime entry points read from `HANDLER_CONFIG` (and `PgRuntime.poolFor`
  reconstructs). One shared producer so all seven deploy-time builders emit a
  byte-identical shape — the field set is a cold-start contract with the entry
  points, so a drift here silently breaks a Lambda. `~lockStrategy` is included
  only on the DCB command path (the sole Postgres append that takes a lock);
  omit it everywhere else. Kept pure (no Pulumi) so it is directly unit-testable. */
let connectionConfigToJson = (
  ~lockStrategy: option<ReventlessPostgres.DcbEventLogStorage_Postgres.lockStrategy>=?,
  cc: connectionConfig,
): JSON.t => {
  let fields = [
    ("host", cc.host->JSON.Encode.string),
    ("port", cc.port->Int.toFloat->JSON.Encode.float),
    ("database", cc.database->JSON.Encode.string),
    ("username", cc.username->JSON.Encode.string),
    ("secretArn", cc.secretArn->JSON.Encode.string),
  ]
  switch lockStrategy {
  | Some(#AdvisoryLocks) => fields->Array.push(("lockStrategy", "AdvisoryLocks"->JSON.Encode.string))
  | Some(#RowLocks) => fields->Array.push(("lockStrategy", "RowLocks"->JSON.Encode.string))
  | None => ()
  }
  fields->Dict.fromArray->JSON.Encode.object
}

type t = {
  /** Deploy-time resources (currently the RDS instance) for dependency wiring —
    e.g. the A3 migration Lambda and the B-phase adapters order after these. */
  resources: array<ReventlessInfra.Adapter.resource>,
  connectionConfig: Pulumi.Output.t<connectionConfig>,
  /** Attach to every Lambda that talks to Postgres: the SG's self-referencing
    rule is what lets those Lambdas reach the DB on 5432. */
  securityGroupId: Pulumi.Output.t<string>,
  /** The DB's private subnets, echoed back for the Lambda `vpcConfig` so
    handlers land in the same subnets as the database. */
  subnetIds: array<Pulumi.Input.t<string>>,
  /** DCB append lock strategy (C2). `#AdvisoryLocks` (default) is
    transaction-scoped and lowest-overhead when Lambdas hold a few long-lived
    pools **directly** against RDS, but it **pins connections on RDS Proxy**
    (advisory locks are session state Proxy cannot multiplex). Choose
    `#RowLocks` when fronting the DB with RDS Proxy so the Proxy can share
    connections across invocations. Threaded to the DCB command Lambda via
    `DcbBackend`; classic EventLog and QueryDb appends take no such lock. */
  lockStrategy: ReventlessPostgres.DcbEventLogStorage_Postgres.lockStrategy,
}

/** Postgres wire port. */
let port = 5432

let make = (
  ~name,
  ~vpcId: Pulumi.Input.t<string>,
  ~subnetIds: array<Pulumi.Input.t<string>>,
  ~databaseName="reventless",
  ~username="reventless_admin",
  ~engineVersion="16",
  ~instanceClass="db.t3.micro",
  ~allocatedStorage=20,
  ~multiAz=false,
  ~storageEncrypted=true,
  ~backupRetentionPeriod=7,
  ~deletionProtection=true,
  ~skipFinalSnapshot=false,
  ~lockStrategy: ReventlessPostgres.DcbEventLogStorage_Postgres.lockStrategy=#AdvisoryLocks,
  ~opts: option<Pulumi.ComponentResource.options>=?,
): t => {
  // Keep the caller's ComponentResource.options for sub-builders that take it
  // directly (PgMigration_Builder → RuntimeEnvironment_Lambda); the RDS/SG/subnet
  // resources below want the CustomResourceOptions form.
  let componentOpts = opts
  let opts =
    opts->Option.map(ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions)

  let tags =
    [
      ("Name", name),
      ("Environment", Pulumi.Pulumi.getStackName()),
      ("reventless:role", "postgres-connection"),
    ]->Dict.fromArray

  // Shared DB-access security group. Self-referencing 5432 ingress lets member
  // Lambdas reach the DB; open egress so both the DB and those Lambdas can make
  // outbound calls (e.g. Secrets Manager, other AWS APIs).
  let sg = PulumiAws.EC2.SecurityGroup.make(
    ~name=`${name}-pg-sg`,
    ~args={
      name: `${name}-pg-sg`,
      vpcId,
      ingress: [
        {
          fromPort: port,
          protocol: "tcp",
          toPort: port,
          cidrBlocks: [],
          self: true,
        },
      ],
      egress: [PulumiAws.EC2.SecurityGroup.Egress.allowAll],
      tags,
    },
    ~opts?,
  )

  let subnetGroup = PulumiAws.Rds.SubnetGroup.make(
    ~name=`${name}-pg-subnets`,
    ~args={
      name: `${name}-pg-subnets`->Pulumi.Input.make,
      subnetIds: subnetIds->Pulumi.Input.make,
      tags: tags->Pulumi.Input.make,
    },
    ~opts?,
  )

  let instance = PulumiAws.Rds.Instance.make(
    ~name=`${name}-pg`,
    ~args={
      engine: "postgres"->Pulumi.Input.make,
      engineVersion: engineVersion->Pulumi.Input.make,
      instanceClass: instanceClass->Pulumi.Input.make,
      allocatedStorage: allocatedStorage->Pulumi.Input.make,
      dbName: databaseName->Pulumi.Input.make,
      username: username->Pulumi.Input.make,
      manageMasterUserPassword: true->Pulumi.Input.make,
      dbSubnetGroupName: subnetGroup.name->Pulumi.Output.asInput,
      vpcSecurityGroupIds: [sg.id->Pulumi.Output.asInput]->Pulumi.Input.make,
      port: port->Pulumi.Input.make,
      multiAz: multiAz->Pulumi.Input.make,
      publiclyAccessible: false->Pulumi.Input.make,
      storageEncrypted: storageEncrypted->Pulumi.Input.make,
      backupRetentionPeriod: backupRetentionPeriod->Pulumi.Input.make,
      deletionProtection: deletionProtection->Pulumi.Input.make,
      skipFinalSnapshot: skipFinalSnapshot->Pulumi.Input.make,
      tags: tags->Pulumi.Input.make,
    },
    ~opts?,
  )

  let connectionConfig =
    (instance.address, instance.masterUserSecrets)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((host, secrets)) => {
      host,
      port,
      database: databaseName,
      username,
      secretArn: switch secrets->Array.get(0) {
      | Some(secret) => secret.secretArn
      | None =>
        JsError.throwWithMessage(
          "RDS instance exposes no master user secret — manageMasterUserPassword must be enabled",
        )
      },
    })

  // A3: run PgSchema.ensureSchema against the fresh instance via a one-shot
  // in-VPC migration Lambda invoked during `pulumi up`. Its resources join the
  // instance's so the B-phase storage adapters can order after the schema exists.
  // The connection is passed as pre-serialized pieces to avoid a module cycle
  // (PgMigration_Builder must not reference this module's `connectionConfig`).
  let migrationHandlerConfig = connectionConfig->Pulumi.Output.apply(cc =>
    `{"pgConnection":${cc->connectionConfigToJson->JSON.stringify}}`
  )
  let migrationResources = PgMigration_Builder.make(
    ~name=`${name}-pg-migrate`,
    ~handlerConfig=migrationHandlerConfig,
    ~secretArn=connectionConfig->Pulumi.Output.apply(cc => cc.secretArn),
    ~securityGroupId=sg.id,
    ~subnetIds,
    ~opts=?componentOpts,
  )

  {
    resources: Array.concat(
      [
        ReventlessInfra.Adapter.make(
          ~name=name->Pulumi.Output.make,
          ~id=instance.id,
          ~urn=instance.arn,
          ~service="aws:rds"->Pulumi.Output.make,
          ~role="postgres"->Pulumi.Output.make,
          ~resourceType="aws:rds:Instance"->Pulumi.Output.make,
        ),
      ],
      migrationResources,
    ),
    connectionConfig,
    securityGroupId: sg.id,
    subnetIds,
    lockStrategy,
  }
}
