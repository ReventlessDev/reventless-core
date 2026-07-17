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

type args = {
  rule: Rule.t,
  arn: Pulumi.Input.t<string>,
  input?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "EventTarget"
