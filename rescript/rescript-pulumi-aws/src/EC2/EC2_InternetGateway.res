/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/internetgateway
*/
type t = {id: Pulumi.Output.t<string>}

type args = {vpcId: Pulumi.Input.t<string>, tags?: Aws.tags}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "InternetGateway"

let make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args=?,
  ~opts=?,
) => {
  make(
    ~name,
    ~args=?args->Option.map(args => {
      vpcId: args.vpcId,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    }),
    ~opts?,
  )
}
