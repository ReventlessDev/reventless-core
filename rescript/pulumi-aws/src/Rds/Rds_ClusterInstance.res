/** @pulumi/aws/rds/clusterinstance
  see: https://www.pulumi.com/registry/packages/aws/api-docs/rds/clusterinstance

  A compute node attached to an `Rds_Cluster`. Use `instanceClass =
  "db.serverless"` for Aurora Serverless v2.
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  /** This node's own endpoint hostname (prefer the cluster writer endpoint). */
  endpoint: Pulumi.Output.t<string>,
  port: Pulumi.Output.t<int>,
}

type args = {
  clusterIdentifier: Pulumi.Input.t<string>,
  instanceClass: Pulumi.Input.t<string>,
  engine: Pulumi.Input.t<string>,
  engineVersion?: Pulumi.Input.t<string>,
  identifier?: Pulumi.Input.t<string>,
  dbSubnetGroupName?: Pulumi.Input.t<string>,
  publiclyAccessible?: Pulumi.Input.t<bool>,
  applyImmediately?: Pulumi.Input.t<bool>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("rds") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "ClusterInstance"
