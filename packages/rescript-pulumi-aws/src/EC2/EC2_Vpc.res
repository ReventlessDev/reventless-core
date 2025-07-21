/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/vpc
*/
type args = {cidrBlock: string, enableDnsHostnames: bool, tags?: Aws.tags}

type t = {id: Pulumi.Output.t<string>}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Vpc"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      cidrBlock: args.cidrBlock,
      enableDnsHostnames: args.enableDnsHostnames,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    },
    ~opts?,
  )
}
