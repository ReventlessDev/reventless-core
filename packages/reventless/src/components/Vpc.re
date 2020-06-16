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
// TODO: add availabilityZone ?
type functionVpcConfig = {
  .
  "securityGroupIds": array(string),
  "subnetIds": array(string),
  "vpcId": string,
};

type outputs = {
  .
  "vpc": PulumiAws.EC2.VPC.t,
  "securityGroup": PulumiAws.EC2.SecurityGroup.t,
  "publicSubnet": PulumiAws.EC2.Subnet.t,
  "privateSubnet": PulumiAws.EC2.Subnet.t,
  "eip": PulumiAws.EC2.Eip.t,
  "natGateway": PulumiAws.EC2.NatGateway.t,
  "internetGateway": PulumiAWs.EC2.InternetGateway.t,
  "publicSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "privateSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "publicSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
  "privateSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
};
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

[@bs.obj]
external makeOutputs:
  (
    ~vpc: PulumiAws.EC2.VPC.t,
    ~securityGroup: PulumiAws.EC2.SecurityGroup.t,
    ~publicSubnet: PulumiAws.EC2.Subnet.t,
    ~privateSubnet: PulumiAws.EC2.Subnet.t,
    ~eip: PulumiAws.EC2.Eip.t,
    ~natGateway: PulumiAws.EC2.NatGateway.t,
    ~internetGateway: PulumiAws.EC2.InternetGateway.t,
    ~publicSubnetRouteTable: PulumiAws.EC2.RouteTable.t,
    ~privateSubnetRouteTable: PulumiAws.EC2.RouteTable.t,
    ~publicSubnetRouteTableAssociation: PulumiAws.EC2.RouteTableAssociation.t,
    ~privateSubnetRouteTableAssociation: PulumiAws.EC2.RouteTableAssociation.t
  ) =>
  outputs =
  "";

[@bs.send] external registerOutputs: (t, outputs) => constructed = "";
[@bs.send] external setOutputs: (t, outputs) => unit = "setOutputs";
let setOutputs = (outputs, self) => {
  self->setOutputs(outputs);
  self->registerOutputs(outputs);
};

let construct: construct =
  (self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let vpc =
      PulumiAws.EC2.VPC.(
        make(
          ~name=name ++ "VPC",
          ~args=Args.make(~cidrBlock="172.31.0.0/16"),
          ~opts,
          (),
        )
      );

    let securityGroup =
      PulumiAws.EC2.SecurityGroup.(
        make(
          ~name=name ++ "SecurityGroup",
          ~args=
            Args.make(
              ~name="todo",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~ingress=[|
                Args.Ingress.make(
                  ~fromPort="todo",
                  ~protocol="todo",
                  ~toPort="todo",
                  cidrBlocks = [|"todo"|],
                ),
              |],
              ~egress=[|
                Args.Egress.make(
                  ~fromPort="todo",
                  ~protocol="todo",
                  ~toPort="todo",
                ),
              |],
            ),
          ~opts,
          (),
        )
      );

    let publicSubnet =
      PulumiAws.EC2.Subnet.(
        make(
          ~name=name ++ "PublicSubnet",
          ~args=
            Args.make(
              ~cidrBlock="172.31.0.0/17",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~availabilityZone="eu-west-1a",
            ),
          ~opts,
          (),
        )
      );

    let privateSubnet =
      PulumiAws.EC2.Subnet.(
        make(
          ~name=name ++ "PrivateSubnet",
          ~args=
            Args.make(
              ~cidrBlock="172.31.128.0/17",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~availabilityZone="eu-west-1a",
            ),
          ~opts,
          (),
        )
      );

    let eip =
      PulumiAws.EC2.Eip.(
        make(~name=name ++ "Eip", ~args=Args.make(~vpc=true), ~opts, ())
      );

    let natGateway =
      PulumiAws.EC2.NatGateway.(
        make(
          ~name=name ++ "NatGateway",
          ~args=
            Args.make(
              ~allocationId=eip##allocationId->Pulumi.Output.asInput,
              ~subnetId=publicSubnet##id->Pulumi.Output.asInput,
            ),
          ~opts,
          (),
        )
      );

    let internetGateway =
      PulumiAws.EC2.InternetGateway.(
        make(
          ~name=name ++ "InternetGateway",
          ~args=Args.make(~vpcId=vpc##id->Pulumi.Output.asInput),
          ~opts,
          (),
        )
      );

    let publicSubnetRouteTable =
      PulumiAws.EC2.RouteTable.(
        make(
          ~name=name ++ "PublicSubnetRouteTable",
          ~args=
            Args.make(
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~routes=[|
                PulumiAws.EC2.RouteTable.Route.makeInternetGatewayRoute(
                  ~cidrBlock="0.0.0.0/0",
                  ~gatewayId=internetGateway##id->Pulumi.Output.asInput,
                ),
              |],
            ),
          ~opts,
          (),
        )
      );

    let privateSubnetRouteTable =
      PulumiAws.EC2.RouteTable.(
        make(
          ~name=name ++ "PrivateSubnetRouteTable",
          ~args=
            Args.make(
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~routes=[|
                PulumiAws.EC2.RouteTable.Route.makeNatGatewayRoute(
                  ~cidrBlock="0.0.0.0/0",
                  ~gatewayId=natGateway##id->Pulumi.Output.asInput,
                ),
              |],
            ),
          ~opts,
          (),
        )
      );

    let publicSubnetRouteTableAssociation =
      PulumiAws.EC2.RouteTableAssociation.(
        make(
          ~name=name ++ "PublicSubnetRouteTableAssociation",
          ~args=
            Args.make(
              ~routeTableId=publicSubnetRouteTable##id->Pulumi.Output.asInput,
              ~subnetId=publicSubnet##id->Pulumi.Output.asInput,
            ),
          ~opts,
          (),
        )
      );

    let privateSubnetRouteTableAssociation =
      PulumiAws.EC2.RouteTableAssociation.(
        make(
          ~name=name ++ "PrivateSubnetRouteTableAssociation",
          ~args=
            Args.make(
              ~routeTableId=privateSubnetRouteTable##id->Pulumi.Output.asInput,
              ~subnetId=privateSubnet##id->Pulumi.Output.asInput,
            ),
          ~opts,
          (),
        )
      );

    makeOutputs(
      ~vpc,
      ~securityGroup,
      ~publicSubnet,
      ~privateSubnet,
      ~eip,
      ~natGateway,
      ~internetGateway,
      ~publicSubnetRouteTable,
      ~privateSubnetRouteTable,
      ~publicSubnetRouteTableAssociation,
      ~privateSubnetRouteTableAssociation,
    )
    ->setOutputs(self);
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
