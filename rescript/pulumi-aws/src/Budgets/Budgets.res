/** @pulumi/aws/budgets/Budget
  see: https://www.pulumi.com/registry/packages/aws/api-docs/budgets/budget

  A budget on the account's costs, and who is told when they cross it.
*/
module Budget = {
  type t = {id: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>}

  /** `{name: "Service", values: ["Amazon Simple Email Service"]}`. */
  type costFilter = {name: string, values: array<string>}

  type notification = {
    /** `GREATER_THAN`. */
    comparisonOperator: string,
    threshold: float,
    /** `PERCENTAGE` or `ABSOLUTE_VALUE`. */
    thresholdType: string,
    /** `ACTUAL` or `FORECASTED`. */
    notificationType: string,
    subscriberEmailAddresses?: Pulumi.Input.t<array<string>>,
    subscriberSnsTopicArns?: Pulumi.Input.t<array<string>>,
  }

  type args = {
    /** `COST`. */
    budgetType: string,
    limitAmount: Pulumi.Input.t<string>,
    limitUnit: string,
    /** `MONTHLY`. */
    timeUnit: string,
    namePrefix?: string,
    costFilters?: array<costFilter>,
    notifications?: array<notification>,
    tags?: Pulumi.Input.t<Aws.tags>,
  }

  @module("@pulumi/aws") @scope("budgets") @new
  external make: (
    ~name: string,
    ~args: args,
    ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  ) => t = "Budget"
}
