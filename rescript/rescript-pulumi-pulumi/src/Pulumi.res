/** @pulumi/pulumi see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi */
@module("@pulumi/pulumi")
external getStackName: unit => string = "getStack"

@module("@pulumi/pulumi")
external getProjectName: unit => string = "getProject"
