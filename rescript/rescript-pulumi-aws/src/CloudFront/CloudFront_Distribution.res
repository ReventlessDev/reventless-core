/** @pulumi/aws/cloudfront/Distribution
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudfront/distribution
*/
type origin = {
  domainName: Pulumi.Input.t<string>,
  originId: Pulumi.Input.t<string>,
  originAccessControlId?: Pulumi.Input.t<string>,
}

type defaultCacheBehavior = {
  targetOriginId: Pulumi.Input.t<string>,
  viewerProtocolPolicy: Pulumi.Input.t<string>,
  allowedMethods: Pulumi.Input.t<array<string>>,
  cachedMethods: Pulumi.Input.t<array<string>>,
  cachePolicyId?: Pulumi.Input.t<string>,
  compress?: Pulumi.Input.t<bool>,
}

type geoRestriction = {
  restrictionType: Pulumi.Input.t<string>,
}

type restrictions = {
  geoRestriction: Pulumi.Input.t<geoRestriction>,
}

type viewerCertificate = {
  cloudfrontDefaultCertificate?: Pulumi.Input.t<bool>,
  acmCertificateArn?: Pulumi.Input.t<string>,
  sslSupportMethod?: Pulumi.Input.t<string>,
  minimumProtocolVersion?: Pulumi.Input.t<string>,
}

type args = {
  enabled: Pulumi.Input.t<bool>,
  origins: Pulumi.Input.t<array<origin>>,
  defaultCacheBehavior: Pulumi.Input.t<defaultCacheBehavior>,
  restrictions: Pulumi.Input.t<restrictions>,
  viewerCertificate: Pulumi.Input.t<viewerCertificate>,
  comment?: Pulumi.Input.t<string>,
  defaultRootObject?: Pulumi.Input.t<string>,
  httpVersion?: Pulumi.Input.t<string>,
  isIpv6Enabled?: Pulumi.Input.t<bool>,
  priceClass?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
  waitForDeployment?: Pulumi.Input.t<bool>,
}

type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  domainName: Pulumi.Output.t<string>,
  hostedZoneId: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("cloudfront") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Distribution"
