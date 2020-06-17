type outputs = {
  .
  "vpc": PulumiAws.EC2.VPC.t,
  "securityGroup": PulumiAws.EC2.SecurityGroup.t,
  "publicSubnet": PulumiAws.EC2.Subnet.t,
  "privateSubnet": PulumiAws.EC2.Subnet.t,
  "eip": PulumiAws.EC2.Eip.t,
  "natGateway": PulumiAws.EC2.NatGateway.t,
  "internetGateway": PulumiAws.EC2.InternetGateway.t,
  "publicSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "privateSubnetRouteTable": PulumiAws.EC2.RouteTable.t,
  "publicSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
  "privateSubnetRouteTableAssociation": PulumiAws.EC2.RouteTableAssociation.t,
};
type t = outputs;

let make:
  (~name: string, ~opts: Pulumi.ComponentResource.Options.t=?, unit) => t;
