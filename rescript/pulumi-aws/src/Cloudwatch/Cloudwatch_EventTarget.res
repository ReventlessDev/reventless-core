/** @pulumi/aws/cloudwatch/eventtarget
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudwatch/eventtarget/
*/
type t

module Rule: {
  type t

  let ofInput: Pulumi.Input.t<string> => t
  let ofString: string => t
  let ofEventRule: Cloudwatch_EventRule.t => t
} = {
  type t = Pulumi.Input.t<string>

  external ofInput: Pulumi.Input.t<string> => t = "%identity"
  let ofString = ruleName => ruleName->Pulumi.Input.make
  let ofEventRule = (rule: Cloudwatch_EventRule.t) => rule.name->Pulumi.Output.asInput
}

/** Rewrites a matched event before it reaches the target. `inputPaths` binds names to
  JSON paths in the event; `inputTemplate` substitutes them where it writes `<name>`.
  A template that is not JSON arrives as plain text — an SNS email body, say.
  see: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-transform-target-input.html */
type inputTransformer = {
  inputPaths?: dict<string>,
  inputTemplate: Pulumi.Input.t<string>,
}

type args = {
  rule: Rule.t,
  arn: Pulumi.Input.t<string>,
  /** A fixed payload, sent verbatim. Mutually exclusive with `inputTransformer`. */
  input?: Pulumi.Input.t<string>,
  inputTransformer?: Pulumi.Input.t<inputTransformer>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "EventTarget"
