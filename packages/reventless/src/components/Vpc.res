let componentType = ComponentType.Vpc
open PulumiAws.EC2

type outputs = {
  "dynamoDbEndpoint": VpcEndpoint.t,
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
  "vpc": PulumiAws.EC2.Vpc.t,
}
type t = outputs

type name = string
type constructed
type construct = (t, name, option<PulumiAws.Aws.AvailabilityZone.t>) => constructed

@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: construct,
  ~opts: option<Pulumi.ComponentResource.options>,
  ~availabilityZone: option<PulumiAws.Aws.AvailabilityZone.t>,
) => t = "default"

@obj
external makeOutputs: (
  ~dynamoDbEndpoint: VpcEndpoint.t,
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
  ~vpc: PulumiAws.EC2.Vpc.t,
) => outputs = ""

@send
external registerOutputs: (t, outputs) => constructed = "registerOutputs"
@send external setOutputs: (t, outputs) => unit = "setOutputs"
let setOutputs = (outputs, self) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}

let construct: construct = (self, name, availabilityZone) => {
  let opts = {Pulumi.CustomResourceOptions.parent: self->Pulumi.Resource.makeFromJs}

  let vpc = PulumiAws.EC2.Vpc.make(
    ~name=name ++ "VPC",
    ~args={cidrBlock: "172.31.0.0/16", enableDnsHostnames: true},
    ~opts,
  )

  let securityGroup = SecurityGroup.make(
    ~name=name ++ "SecurityGroup",
    ~args={
      open SecurityGroup
      {
        name: name ++ "SecurityGroup",
        vpcId: vpc.id->Pulumi.Output.asInput,
        ingress: [Ingress.allowAll],
        egress: [Egress.allowAll],
      }
    },
    ~opts,
  )

  let publicSubnet = Subnet.make(
    ~name=name ++ "PublicSubnet",
    ~args={
      cidrBlock: "172.31.0.0/17",
      vpcId: vpc.id->Pulumi.Output.asInput,
      ?availabilityZone,
    },
    ~opts,
  )

  let privateSubnet = Subnet.make(
    ~name=name ++ "PrivateSubnet",
    ~args={
      cidrBlock: "172.31.128.0/17",
      vpcId: vpc.id->Pulumi.Output.asInput,
      ?availabilityZone,
    },
    ~opts,
  )

  let internetGateway = InternetGateway.make(
    ~name=name ++ "InternetGateway",
    ~args={vpcId: vpc.id->Pulumi.Output.asInput},
    ~opts,
  )

  let eip = Eip.make(
    ~name=name ++ "Eip",
    ~args={vpc: true},
    ~opts={
      parent: self->Pulumi.Resource.makeFromJs,
      dependsOn: [internetGateway->Pulumi.Resource.makeFromJs]->Pulumi.Input.make,
    },
  )

  let natGateway = NatGateway.make(
    ~name=name ++ "NatGateway",
    ~args={
      allocationId: eip.id->Pulumi.Output.asInput,
      subnetId: publicSubnet.id->Pulumi.Output.asInput,
    },
    ~opts={
      parent: self->Pulumi.Resource.makeFromJs,
      dependsOn: [internetGateway->Pulumi.Resource.makeFromJs]->Pulumi.Input.make,
    },
  )

  let publicSubnetRouteTable = RouteTable.make(
    ~name=name ++ "PublicSubnetRouteTable",
    ~args={
      vpcId: vpc.id->Pulumi.Output.asInput,
      routes: [
        RouteTable.Route.makeInternetGatewayRoute(
          ~cidrBlock="0.0.0.0/0",
          ~gatewayId=internetGateway.id->Pulumi.Output.asInput,
        ),
      ],
    },
    ~opts,
  )

  let privateSubnetRouteTable = RouteTable.make(
    ~name=name ++ "PrivateSubnetRouteTable",
    ~args={
      vpcId: vpc.id->Pulumi.Output.asInput,
      routes: [
        RouteTable.Route.makeNatGatewayRoute(
          ~cidrBlock="0.0.0.0/0",
          ~natGatewayId=natGateway.id->Pulumi.Output.asInput,
        ),
      ],
    },
    ~opts,
  )

  let publicSubnetRouteTableAssociation = RouteTableAssociation.make(
    ~name=name ++ "PublicSubnetRouteTableAssociation",
    ~args={
      routeTableId: publicSubnetRouteTable.id->Pulumi.Output.asInput,
      subnetId: publicSubnet.id->Pulumi.Output.asInput,
    },
    ~opts,
  )

  let privateSubnetRouteTableAssociation = RouteTableAssociation.make(
    ~name=name ++ "PrivateSubnetRouteTableAssociation",
    ~args={
      routeTableId: privateSubnetRouteTable.id->Pulumi.Output.asInput,
      subnetId: privateSubnet.id->Pulumi.Output.asInput,
    },
    ~opts,
  )

  let region = PulumiAws.Aws.getRegion()
  let service = async serviceName => `com.amazonaws.${(await region).name}.${serviceName}`

  let routeTableIds = [
    publicSubnetRouteTable.id->Pulumi.Output.asInput,
    privateSubnetRouteTable.id->Pulumi.Output.asInput,
  ]

  let s3Endpoint = VpcEndpoint.make(
    ~name=name ++ "S3Endpoint",
    ~args={
      serviceName: service("s3")->Pulumi.Input.ofPromise,
      vpcId: vpc.id->Pulumi.Output.asInput,
      routeTableIds,
    },
    ~opts,
  )

  let dynamoDbEndpoint = VpcEndpoint.make(
    ~name=name ++ "DynamoDbEndpoint",
    ~args={
      serviceName: service("dynamodb")->Pulumi.Input.ofPromise,
      vpcId: vpc.id->Pulumi.Output.asInput,
      routeTableIds,
    },
    ~opts,
  )

  self->setOutputs(
    makeOutputs(
      ~dynamoDbEndpoint,
      ~eip,
      ~internetGateway,
      ~natGateway,
      ~privateSubnet,
      ~privateSubnetRouteTable,
      ~privateSubnetRouteTableAssociation,
      ~publicSubnet,
      ~publicSubnetRouteTable,
      ~publicSubnetRouteTableAssociation,
      ~s3Endpoint,
      ~securityGroup,
      ~vpc,
    ),
  )
}

let make: (
  ~name: string,
  ~availabilityZone: PulumiAws.Aws.AvailabilityZone.t=?,
  ~opts: Pulumi.ComponentResource.options=?
) => t = (~name, ~availabilityZone=?, ~opts=?) =>
  make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct,
    ~opts,
    ~availabilityZone,
  )
