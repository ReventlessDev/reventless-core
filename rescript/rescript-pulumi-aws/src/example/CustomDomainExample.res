// Compile-only smoke for the ACM / Route53 / Provider bindings used by
// custom-domain provisioning. Not executed at deploy time — its sole job is
// to keep the four new bindings type-checked together (alt-region provider →
// cert → DNS validation record → cert validation → Route53 alias on a
// fictitious distribution domain). See docs/plans/done/host-ui-custom-domain.md.

let usEast1 = Aws.Provider.make(
  ~name="example-us-east-1",
  ~args={region: Pulumi.Input.make("us-east-1")},
)

let cert = Acm.Certificate.make(
  ~name="example-cert",
  ~args={
    domainName: Pulumi.Input.make("example.app.reventless.dev"),
    validationMethod: Pulumi.Input.make("DNS"),
  },
  ~opts={provider: usEast1},
)

let firstValidationOption = cert.domainValidationOptions->Pulumi.Output.apply(opts =>
  opts->Array.getUnsafe(0)
)

let validationRecord = Route53.Record.make(
  ~name="example-cert-validation",
  ~args={
    zoneId: Pulumi.Input.make("Z00000000000000000000"),
    name: firstValidationOption
    ->Pulumi.Output.apply(o => o.resourceRecordName)
    ->Pulumi.Output.asInput,
    type_: firstValidationOption
    ->Pulumi.Output.apply(o => o.resourceRecordType)
    ->Pulumi.Output.asInput,
    ttl: Pulumi.Input.make(60),
    records: firstValidationOption
    ->Pulumi.Output.apply(o => [o.resourceRecordValue])
    ->Pulumi.Output.asInput,
  },
)

let validated = Acm.CertificateValidation.make(
  ~name="example-cert-validated",
  ~args={
    certificateArn: cert.arn->Pulumi.Output.asInput,
    validationRecordFqdns: [validationRecord.fqdn]
    ->Pulumi.Output.all
    ->Pulumi.Output.asInput,
  },
  ~opts={provider: usEast1},
)

let _aliasRecord = Route53.Record.make(
  ~name="example-alias",
  ~args={
    zoneId: Pulumi.Input.make("Z00000000000000000000"),
    name: Pulumi.Input.make("example.app.reventless.dev"),
    type_: Pulumi.Input.make("A"),
    aliases: [
      (
        {
          name: Pulumi.Input.make("d123abc.cloudfront.net"),
          zoneId: Pulumi.Input.make("Z2FDTNDATAQYW2"),
          evaluateTargetHealth: Pulumi.Input.make(false),
        }: Route53.Record.alias
      ),
    ]->Pulumi.Input.make,
  },
)

let _certArn = validated.certificateArn
