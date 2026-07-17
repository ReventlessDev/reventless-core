/**
  Creates a VpcConfig from a VPC component in another stack
 */
let getVpcConfig: (
  ~stackName: string,
  ~outputName: string,
) => Pulumi.Output.t<PulumiAws.Lambda.CallbackFunction.Args.vpcConfig> = (
  ~stackName,
  ~outputName,
) => {
  let stackReference = Pulumi.StackReference.make(stackName)
  let vpcOutput = stackReference->Pulumi.StackReference.requireOutput(outputName->Pulumi.Input.make)
  vpcOutput->Pulumi.Output.apply(vpc =>
    switch (vpc["securityGroup"]["id"], vpc["privateSubnet"]["id"], vpc["vpc"]["id"]) {
    | (Some(securityGroupId), Some(subnetId), Some(_vpcId)) => {
        PulumiAws.Lambda.CallbackFunction.Args.securityGroupIds: [securityGroupId],
        subnetIds: [subnetId],
      }
    | _ => JsError.throwWithMessage("Output is not a ReventlessCore Vpc Component")
    }
  )
}
