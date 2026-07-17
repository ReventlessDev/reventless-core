/** @pulumi/aws/acm/Certificate
  see: https://www.pulumi.com/registry/packages/aws/api-docs/acm/certificate
*/
type domainValidationOption = {
  domainName: string,
  resourceRecordName: string,
  resourceRecordType: string,
  resourceRecordValue: string,
}

type args = {
  domainName: Pulumi.Input.t<string>,
  validationMethod: Pulumi.Input.t<string>,
  subjectAlternativeNames?: Pulumi.Input.t<array<string>>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  domainName: Pulumi.Output.t<string>,
  domainValidationOptions: Pulumi.Output.t<array<domainValidationOption>>,
}

@module("@pulumi/aws") @scope("acm") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Certificate"
