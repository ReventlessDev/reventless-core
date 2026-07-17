/** @pulumi/aws/rds/proxy
  see: https://www.pulumi.com/registry/packages/aws/api-docs/rds/proxy

  RDS Proxy multiplexes many Lambda-container connections onto a small pool of
  DB connections. At Lambda fan-out scale this is the recommended fronting for
  RDS/Aurora; pair with the `#RowLocks` DCB strategy (advisory locks pin
  connections and defeat the proxy — see the AWS-deployment guide).
*/
type auth = {
  authScheme?: string,
  iamAuth?: string,
  secretArn?: Pulumi.Input.t<string>,
  description?: string,
}

type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  /** Proxy endpoint hostname — Lambdas connect here instead of the DB. */
  endpoint: Pulumi.Output.t<string>,
}

type args = {
  name?: Pulumi.Input.t<string>,
  engineFamily: Pulumi.Input.t<string>,
  auths: Pulumi.Input.t<array<Pulumi.Input.t<auth>>>,
  roleArn: Pulumi.Input.t<string>,
  vpcSubnetIds: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  vpcSecurityGroupIds?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  requireTls?: Pulumi.Input.t<bool>,
  idleClientTimeout?: Pulumi.Input.t<int>,
  debugLogging?: Pulumi.Input.t<bool>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("rds") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Proxy"
