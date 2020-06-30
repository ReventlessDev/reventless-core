let componentType = ComponentType.Vpc;
open PulumiAws.EC2;

type outputs = {
  .
  "eip": Eip.t,
  "internetGateway": InternetGateway.t,
  "natGateway": NatGateway.t,
  "privateSubnet": Subnet.t,
  "privateSubnetRouteTable": RouteTable.t,
  "privateSubnetRouteTableAssociation": RouteTableAssociation.t,
  "publicSubnet": Subnet.t,
  "publicSubnetRouteTable": RouteTable.t,
  "publicSubnetRouteTableAssociation": RouteTableAssociation.t,
  "s3Endpoint": VpcEndpoint.t,
  "securityGroup": SecurityGroup.t,
  "sqsEndpoint": VpcEndpoint.t,
  "vpc": PulumiAws.EC2.Vpc.t,
};
type t = outputs;

type name = string;
type constructed;
type construct =
  (t, name, option(PulumiAws.Aws.AvailabilityZone.t)) => constructed;

[@bs.module "./Component"] [@bs.new]
external make:
  (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option(Pulumi.ComponentResource.Options.t),
    ~availabilityZone: option(PulumiAws.Aws.AvailabilityZone.t)
  ) =>
  t =
  "default";

[@bs.obj]
external makeOutputs:
  (
    ~eip: Eip.t,
    ~internetGateway: InternetGateway.t,
    ~natGateway: NatGateway.t,
    ~privateSubnet: Subnet.t,
    ~privateSubnetRouteTable: RouteTable.t,
    ~privateSubnetRouteTableAssociation: RouteTableAssociation.t,
    ~publicSubnet: Subnet.t,
    ~publicSubnetRouteTable: RouteTable.t,
    ~publicSubnetRouteTableAssociation: RouteTableAssociation.t,
    ~s3Endpoint: VpcEndpoint.t,
    ~securityGroup: SecurityGroup.t,
    ~sqsEndpoint: VpcEndpoint.t,
    ~vpc: PulumiAws.EC2.Vpc.t
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
  (self, name, availabilityZone) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Pulumi.Resource.makeFromJs,
        (),
      );

    let vpc =
      PulumiAws.EC2.Vpc.(
        make(
          ~name=name ++ "VPC",
          ~args=Args.make(~cidrBlock="172.31.0.0/16", ()),
          ~opts,
          (),
        )
      );

    let securityGroup =
      SecurityGroup.(
        make(
          ~name=name ++ "SecurityGroup",
          ~args=
            Args.make(
              ~name=name ++ "SecurityGroup",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~ingress=[|Args.Ingress.allowAll|],
              ~egress=[|Args.Egress.allowAll|],
              (),
            ),
          ~opts,
          (),
        )
      );

    let publicSubnet =
      Subnet.(
        make(
          ~name=name ++ "PublicSubnet",
          ~args=
            Args.make(
              ~cidrBlock="172.31.0.0/17",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~availabilityZone?,
              (),
            ),
          ~opts,
          (),
        )
      );

    let privateSubnet =
      Subnet.(
        make(
          ~name=name ++ "PrivateSubnet",
          ~args=
            Args.make(
              ~cidrBlock="172.31.128.0/17",
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~availabilityZone?,
              (),
            ),
          ~opts,
          (),
        )
      );

    let internetGateway =
      InternetGateway.(
        make(
          ~name=name ++ "InternetGateway",
          ~args=Args.make(~vpcId=vpc##id->Pulumi.Output.asInput, ()),
          ~opts,
          (),
        )
      );

    let eip =
      Eip.(
        make(
          ~name=name ++ "Eip",
          ~args=Args.make(~vpc=true, ()),
          ~opts=
            Pulumi.CustomResourceOptions.make(
              ~parent=self->Pulumi.Resource.makeFromJs,
              ~dependsOn=[|internetGateway->Pulumi.Resource.makeFromJs|],
              (),
            ),
          (),
        )
      );

    let natGateway =
      NatGateway.(
        make(
          ~name=name ++ "NatGateway",
          ~args=
            Args.make(
              ~allocationId=eip##id->Pulumi.Output.asInput,
              ~subnetId=publicSubnet##id->Pulumi.Output.asInput,
              (),
            ),
          ~opts=
            Pulumi.CustomResourceOptions.make(
              ~parent=self->Pulumi.Resource.makeFromJs,
              ~dependsOn=[|internetGateway->Pulumi.Resource.makeFromJs|],
              (),
            ),
          (),
        )
      );

    let publicSubnetRouteTable =
      RouteTable.(
        make(
          ~name=name ++ "PublicSubnetRouteTable",
          ~args=
            Args.make(
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~routes=[|
                Args.Route.makeInternetGatewayRoute(
                  ~cidrBlock="0.0.0.0/0",
                  ~gatewayId=internetGateway##id->Pulumi.Output.asInput,
                ),
              |],
              (),
            ),
          ~opts,
          (),
        )
      );

    let privateSubnetRouteTable =
      RouteTable.(
        make(
          ~name=name ++ "PrivateSubnetRouteTable",
          ~args=
            Args.make(
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              ~routes=[|
                Args.Route.makeNatGatewayRoute(
                  ~cidrBlock="0.0.0.0/0",
                  ~natGatewayId=natGateway##id->Pulumi.Output.asInput,
                ),
              |],
              (),
            ),
          ~opts,
          (),
        )
      );

    let publicSubnetRouteTableAssociation =
      RouteTableAssociation.(
        make(
          ~name=name ++ "PublicSubnetRouteTableAssociation",
          ~args=
            Args.make(
              ~routeTableId=publicSubnetRouteTable##id->Pulumi.Output.asInput,
              ~subnetId=publicSubnet##id->Pulumi.Output.asInput,
              (),
            ),
          ~opts,
          (),
        )
      );

    let privateSubnetRouteTableAssociation =
      RouteTableAssociation.(
        make(
          ~name=name ++ "PrivateSubnetRouteTableAssociation",
          ~args=
            Args.make(
              ~routeTableId=privateSubnetRouteTable##id->Pulumi.Output.asInput,
              ~subnetId=privateSubnet##id->Pulumi.Output.asInput,
              (),
            ),
          ~opts,
          (),
        )
      );

    let _ =
      securityGroup##id
      ->Pulumi.Output.apply(id => id |> Js.log2("SecurityGroup.id"));
    let region = PulumiAws.Aws.getRegion();
    region
    |> Js.Promise.then_(region =>
         Js.log2("AWSRegion:", region)->Js.Promise.resolve
       );

    let s3Endpoint =
      VpcEndpoint.(
        make(
          ~name=name ++ "S3Endpoint",
          ~args=
            Args.make(
              ~serviceName=
                (
                  region
                  |> Js.Promise.then_(region =>
                       ("com.amazonaws." ++ region##name ++ ".s3")
                       ->Js.Promise.resolve
                     )
                )
                ->Pulumi.Input.ofPromise,
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              (),
            ),
          ~opts,
          (),
        )
      );

    let sqsEndpoint =
      VpcEndpoint.(
        make(
          ~name=name ++ "SQSEndpoint",
          ~args=
            Args.make(
              ~privateDnsEnabled=true,
              ~securityGroupIds=[|securityGroup##id->Pulumi.Output.asInput|],
              ~serviceName=
                (region
                |> Js.Promise.then_(region =>
                     ("com.amazonaws." ++ region##name ++ ".sqs")
                     ->Js.Promise.resolve
                   ))
                   ->Pulumi.Input.ofPromise,
              ~vpcEndpointType=Args.VpcEndpointType.interface,
              ~vpcId=vpc##id->Pulumi.Output.asInput,
              (),
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
      ~s3Endpoint,
      ~privateSubnetRouteTableAssociation,
      ~sqsEndpoint,
    )
    ->setOutputs(self);
  };

let make:
  (
    ~name: string,
    ~availabilityZone: PulumiAws.Aws.AvailabilityZone.t=?,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit
  ) =>
  t =
  (~name, ~availabilityZone=?, ~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=name->ComponentType.name(componentType),
      ~construct,
      ~opts,
      ~availabilityZone,
    );
  };
