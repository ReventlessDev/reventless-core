/** @pulumi/aws/route53/Record
  see: https://www.pulumi.com/registry/packages/aws/api-docs/route53/record

  Two shapes are supported on the Route53 wire:
    - **Plain DNS record**: set `records` (and `ttl`); leave `aliases` unset.
      Used for cert validation (CNAME) and any vanilla A/AAAA/TXT record.
    - **Alias record**: set `aliases`; leave `records` and `ttl` unset.
      Used to point a name at a CloudFront distribution / ALB / etc.
  The two are mutually exclusive in the AWS API; expressed here as two
  optional fields on a single ReScript type to match the wire shape.
*/
type alias = {
  name: Pulumi.Input.t<string>,
  zoneId: Pulumi.Input.t<string>,
  evaluateTargetHealth: Pulumi.Input.t<bool>,
}

type args = {
  zoneId: Pulumi.Input.t<string>,
  name: Pulumi.Input.t<string>,
  @as("type") type_: Pulumi.Input.t<string>,
  ttl?: Pulumi.Input.t<int>,
  records?: Pulumi.Input.t<array<string>>,
  aliases?: Pulumi.Input.t<array<alias>>,
  allowOverwrite?: Pulumi.Input.t<bool>,
}

type t = {
  id: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  fqdn: Pulumi.Output.t<string>,
  zoneId: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("route53") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Record"
