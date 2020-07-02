type outputs = {
  .
  "dynamoDbEndpoint": PulumiAws.EC2.VpcEndpoint.t,
  "eip": PulumiAws.EC2.Eip.t,
  "internetGateway": PulumiAws.EC2.InternetGateway.t,
  "natGateway": PulumiAws.EC2.NatGateway.t,
  "privateSubnet": PulumiAws.EC2.Subnet.t,
  "privateSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "privateSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
  "publicSubnet": PulumiAws.EC2.Subnet.t,
  "publicSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "publicSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
  "s3Endpoint": PulumiAws.EC2.VpcEndpoint.t,
  "securityGroup": PulumiAws.EC2.SecurityGroup.t,
  "vpc": PulumiAws.EC2.Vpc.t,
};
type t = outputs;

let make:
  (
    ~name: string,
    ~availabilityZone: PulumiAws.Aws.AvailabilityZone.t=?,
    ~opts: Pulumi.ComponentResource.Options.t=?,
    unit
  ) =>
  t;
