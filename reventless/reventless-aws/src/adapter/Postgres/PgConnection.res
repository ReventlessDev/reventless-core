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
  ~opts: option<Pulumi.ComponentResource.options>=?,
): t => {
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

  {
    resources: [
      ReventlessInfra.Adapter.make(
        ~name=name->Pulumi.Output.make,
        ~id=instance.id,
        ~urn=instance.arn,
        ~service="aws:rds"->Pulumi.Output.make,
        ~role="postgres"->Pulumi.Output.make,
        ~resourceType="aws:rds:Instance"->Pulumi.Output.make,
      ),
    ],
    connectionConfig,
    securityGroupId: sg.id,
    subnetIds,
  }
}
