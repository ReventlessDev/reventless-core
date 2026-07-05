/** @pulumi/aws/rds/cluster
  see: https://www.pulumi.com/registry/packages/aws/api-docs/rds/cluster

  Aurora (incl. Aurora Serverless v2) Postgres cluster. Pair with one or more
  `Rds_ClusterInstance` — a cluster has no compute of its own.
*/

/** See `Rds_Instance.masterUserSecret`. */
type masterUserSecret = {
  kmsKeyId: string,
  secretArn: string,
  secretStatus: string,
}

/** Aurora Serverless v2 autoscaling bounds, in ACUs (0.5-increment floats). */
type serverlessv2ScalingConfiguration = {
  maxCapacity: float,
  minCapacity: float,
}

type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  clusterIdentifier: Pulumi.Output.t<string>,
  /** Writer endpoint hostname. */
  endpoint: Pulumi.Output.t<string>,
  /** Load-balanced reader endpoint hostname. */
  readerEndpoint: Pulumi.Output.t<string>,
  port: Pulumi.Output.t<int>,
  databaseName: Pulumi.Output.t<string>,
  masterUsername: Pulumi.Output.t<string>,
  masterUserSecrets: Pulumi.Output.t<array<masterUserSecret>>,
}

type args = {
  engine: Pulumi.Input.t<string>,
  engineMode?: Pulumi.Input.t<string>,
  engineVersion?: Pulumi.Input.t<string>,
  clusterIdentifier?: Pulumi.Input.t<string>,
  databaseName?: Pulumi.Input.t<string>,
  masterUsername?: Pulumi.Input.t<string>,
  masterPassword?: Pulumi.Input.t<string>,
  manageMasterUserPassword?: Pulumi.Input.t<bool>,
  dbSubnetGroupName?: Pulumi.Input.t<string>,
  vpcSecurityGroupIds?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  port?: Pulumi.Input.t<int>,
  serverlessv2ScalingConfiguration?: Pulumi.Input.t<serverlessv2ScalingConfiguration>,
  storageEncrypted?: Pulumi.Input.t<bool>,
  backupRetentionPeriod?: Pulumi.Input.t<int>,
  deletionProtection?: Pulumi.Input.t<bool>,
  skipFinalSnapshot?: Pulumi.Input.t<bool>,
  finalSnapshotIdentifier?: Pulumi.Input.t<string>,
  applyImmediately?: Pulumi.Input.t<bool>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("rds") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Cluster"
