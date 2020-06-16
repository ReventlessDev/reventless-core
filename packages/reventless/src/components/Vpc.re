let componentType = ComponentType.Vpc;

/*
 interface FunctionVpcConfig {
     /**
      * A list of security group IDs associated with the Lambda function.
      */
     securityGroupIds: pulumi.Input<pulumi.Input<string>[]>;
     /**
      * A list of subnet IDs associated with the Lambda function.
      */
     subnetIds: pulumi.Input<pulumi.Input<string>[]>;
     vpcId?: pulumi.Input<string>;
     */
// TODO: use Pulumi specific types
type functionVpcConfig = {
  .
  "securityGroupIds": array(string),
  "subnetIds": array(string),
  "vpcId": string,
};

type outputs = {. "vpc": string};
type t = outputs;

type constructed;
type construct = (t, string) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t)
  ) =>
  t =
  "default";

// TODO: use Pulumi specific types
[@bs.obj] external makeOutputs: (~vpc: string) => outputs = "";

[@bs.send] external registerOutputs: (t, outputs) => constructed = "";
[@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
let setOutputs = (outputs, self) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct: construct =
  (self, _name) => {
    // TODO: implement vpc setup
    makeOutputs(~vpc="xx")->setOutputs(self);
  };

let make:
  (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => t =
  (~name, ~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=name->ComponentType.name(componentType),
      ~construct,
      ~opts,
    );
  };
