/** @pulumi/aws/acm/CertificateValidation
  see: https://www.pulumi.com/registry/packages/aws/api-docs/acm/certificatevalidation

  Synthetic resource that blocks until ACM marks the referenced certificate
  ISSUED. Downstream resources that consume the validated cert ARN (e.g. a
  CloudFront distribution with `viewerCertificate.acmCertificateArn`) should
  reference `t.certificateArn` from this resource — not the cert's own ARN —
  so Pulumi waits for issuance before wiring them up.
*/
type args = {
  certificateArn: Pulumi.Input.t<string>,
  validationRecordFqdns?: Pulumi.Input.t<array<string>>,
}

type t = {
  id: Pulumi.Output.t<string>,
  certificateArn: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("acm") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "CertificateValidation"
