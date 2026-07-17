/** @pulumi/aws/rds/instance
  see: https://www.pulumi.com/registry/packages/aws/api-docs/rds/instance
*/

/** One entry of `masterUserSecrets`, populated when `manageMasterUserPassword`
  is true — RDS creates and rotates the master password in Secrets Manager and
  reports the secret ARN here. */
type masterUserSecret = {
  kmsKeyId: string,
  secretArn: string,
  secretStatus: string,
}

type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  /** Hostname of the instance (no port). */
  address: Pulumi.Output.t<string>,
  /** `address:port`. */
  endpoint: Pulumi.Output.t<string>,
  port: Pulumi.Output.t<int>,
  dbName: Pulumi.Output.t<string>,
  username: Pulumi.Output.t<string>,
  /** Present when `manageMasterUserPassword=true`. */
  masterUserSecrets: Pulumi.Output.t<array<masterUserSecret>>,
}

type args = {
  allocatedStorage?: Pulumi.Input.t<int>,
  maxAllocatedStorage?: Pulumi.Input.t<int>,
  engine: Pulumi.Input.t<string>,
  engineVersion?: Pulumi.Input.t<string>,
  instanceClass: Pulumi.Input.t<string>,
  /** Name of the initial database created inside the instance. */
  dbName?: Pulumi.Input.t<string>,
  identifier?: Pulumi.Input.t<string>,
  username?: Pulumi.Input.t<string>,
  password?: Pulumi.Input.t<string>,
  /** Let RDS manage the master password in Secrets Manager (mutually
    exclusive with `password`). Secret ARN surfaces on `masterUserSecrets`. */
  manageMasterUserPassword?: Pulumi.Input.t<bool>,
  dbSubnetGroupName?: Pulumi.Input.t<string>,
  vpcSecurityGroupIds?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  port?: Pulumi.Input.t<int>,
  multiAz?: Pulumi.Input.t<bool>,
  publiclyAccessible?: Pulumi.Input.t<bool>,
  storageEncrypted?: Pulumi.Input.t<bool>,
  backupRetentionPeriod?: Pulumi.Input.t<int>,
  deletionProtection?: Pulumi.Input.t<bool>,
  skipFinalSnapshot?: Pulumi.Input.t<bool>,
  finalSnapshotIdentifier?: Pulumi.Input.t<string>,
  applyImmediately?: Pulumi.Input.t<bool>,
  parameterGroupName?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("rds") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Instance"
