/** @pulumi/aws/iam
  see: https://www.pulumi.com/registry/packages/aws/api-docs/iam/getpolicydocument
*/
type principal = {identifiers: array<string>, @as("type") type_: string}

type statement = {
  actions: array<string>,
  principals: array<principal>,
  resources: array<string>,
}

type args = {statements: array<statement>}

@val @module("@pulumi/aws") @scope("iam")
external getPolicyDocument: (
  ~args: args=?,
  ~opts: Pulumi.InvokeOptions.t=?,
) => promise<PolicyDocument.t> = "getPolicyDocument"

/** @pulumi/aws/iam
  see: https://www.pulumi.com/registry/packages/aws/api-docs/iam/policy
*/
module Policy = {
  type t = {arn: Pulumi.Output.t<Aws.arn>}

  type args = {
    policy: Pulumi.Input.t<string>,
    description?: Pulumi.Input.t<string>,
    name?: Pulumi.Input.t<string>,
    namePrefix?: Pulumi.Input.t<string>,
    path?: Pulumi.Input.t<string>,
    tags?: Pulumi.Input.t<Aws.tags>,
  }

  @module("@pulumi/aws") @scope("iam") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Policy"

  let assumeRolePolicy = (name, serviceId) =>
    PolicyDocument.make(
      ~id=name ++ "TrustPolicy",
      ~statements=[
        {
          sid: name->String.split("-")->Array.getUnsafe(0) ++ "TrustPolicyStatement",
          principal: PolicyDocument.Principals({service: PrincipalId(serviceId)}),
          effect: PolicyDocument.Allow,
          actions: PolicyDocument.Action("sts:AssumeRole"),
        },
      ],
    )->PolicyDocument.toJsonString
}

module InlinePolicy = {
  type t = {name: string, policy: string}

  let makeForActions = (~name, ~actions) => {
    {
      name,
      policy: PolicyDocument.make(
        ~statements=[
          {
            sid: "InlinePolicyAllow",
            effect: PolicyDocument.Allow,
            actions: PolicyDocument.Actions(actions),
            resources: PolicyDocument.AllResources,
          },
        ],
      )->PolicyDocument.toJsonString,
    }
  }
}

module Role = {
  type t = {
    arn: Pulumi.Output.t<string>,
    name: Pulumi.Output.t<string>,
    id: Pulumi.Output.t<string>,
  }

  type args = {
    name?: Pulumi.Input.t<string>,
    assumeRolePolicy: Pulumi.Input.t<string>,
    inlinePolicies?: Pulumi.Input.t<array<InlinePolicy.t>>, //deprecated
    tags?: Pulumi.Input.t<Aws.tags>,
  }

  @module("@pulumi/aws") @scope("iam") @new
  external make: (
    ~name: string,
    ~args: args=?,
    ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  ) => t = "Role"

  let makeWithDefaultPolicy = (
    ~name: string,
    ~servicePrincipal: Pulumi.Output.t<string>,
    ~tags: option<Pulumi.Input.t<Aws.tags>>=?,
    ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  ) =>
    make(
      ~name,
      ~args={
        assumeRolePolicy: servicePrincipal
        ->Pulumi.Output.apply(principal => Policy.assumeRolePolicy(name, principal))
        ->Pulumi.Output.asInput,
        tags: ?tags,
      },
      ~opts,
    )

  @module("@pulumi/aws") @scope(("iam", "Role"))
  external get: (
    ~name: string,
    ~id: Pulumi.Input.t<string>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => t = "get"
}

module RolePolicy = {
  type t = {
    arn: Pulumi.Output.t<string>,
    name: Pulumi.Output.t<string>,
    id: Pulumi.Output.t<string>,
  }

  type args = {
    name?: Pulumi.Input.t<string>,
    policy: Pulumi.Input.t<string>,
    role: Pulumi.Input.t<string>,
    tags?: Pulumi.Input.t<Aws.tags>,
  }

  @module("@pulumi/aws") @scope("iam") @new
  external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "RolePolicy"
}

module RolePolicyAttachment = {
  type t = {id: Pulumi.Output.t<string>}

  type args = {policyArn: Pulumi.Input.t<string>, role: Pulumi.Input.t<string>}

  @module("@pulumi/aws") @scope("iam") @new
  external make: (
    ~name: string,
    ~args: args=?,
    ~opts: option<Pulumi.CustomResourceOptions.t>,
  ) => t = "RolePolicyAttachment"
}

module ManagedPolicies = IAM_ManagedPolicies
