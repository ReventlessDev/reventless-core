/**
 * Creates a VpcConfig from a VPC component in another stack
 */
let getVpcConfig:
  (~stackName: string, ~outputName: string) =>
  Pulumi.Input.t(PulumiAws.Lambda.CallbackFunction.Args.VpcConfig.t) =
  (~stackName, ~outputName) => {
    let stackReference = Pulumi.StackReference.make(stackName);
    let vpcOutput =
      stackReference->Pulumi.StackReference.getOutput(outputName);

    switch (vpcOutput) {
    | Some(vpcOutput) =>
      vpcOutput
      ->Pulumi.Output.apply(vpc =>
          switch (vpc##securityGroup##id, vpc##privateSubnet##id) {
          | (Some(securityGroupId), Some(subnetId)) =>
            PulumiAws.Lambda.CallbackFunction.Args.VpcConfig.make(
              ~securityGroupIds=[|securityGroupId|],
              ~subnetIds=[|subnetId|],
              ~vpcId=None,
            )
          | _ => Js.Exn.raiseError("Output is not a Reventless Vpc Component")
          }
        )
      ->Pulumi.Output.asInput
    | None =>
      Js.Exn.raiseError(
        {j|Vpc Output ($outputName) not found in stack ($stackName)|j},
      )
    };
  };
