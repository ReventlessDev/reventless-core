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

// orderedCacheBehavior shares defaultCacheBehavior's shape but adds a
// pathPattern selector — CloudFront evaluates these in order and the first
// match wins; entries without a match fall back to the default behavior.
type orderedCacheBehavior = {
  pathPattern: Pulumi.Input.t<string>,
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

type customErrorResponse = {
  errorCode: Pulumi.Input.t<int>,
  responseCode?: Pulumi.Input.t<int>,
  responsePagePath?: Pulumi.Input.t<string>,
  errorCachingMinTtl?: Pulumi.Input.t<int>,
}

type args = {
  enabled: Pulumi.Input.t<bool>,
  aliases?: Pulumi.Input.t<array<string>>,
  origins: Pulumi.Input.t<array<origin>>,
  defaultCacheBehavior: Pulumi.Input.t<defaultCacheBehavior>,
  orderedCacheBehaviors?: Pulumi.Input.t<array<orderedCacheBehavior>>,
  restrictions: Pulumi.Input.t<restrictions>,
  viewerCertificate: Pulumi.Input.t<viewerCertificate>,
  comment?: Pulumi.Input.t<string>,
  customErrorResponses?: Pulumi.Input.t<array<customErrorResponse>>,
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
