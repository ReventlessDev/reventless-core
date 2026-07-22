/** @pulumi/aws/ecs/taskdefinition
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ecs/taskdefinition/
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  revision: Pulumi.Output.t<int>,
}

type args = {
  /** unique name for your task definition. */
  family: Pulumi.Input.t<string>,
  /** A list of valid container definitions provided as a single valid JSON document. */
  containerDefinitions: Pulumi.Input.t<string>,
  /** Number of cpu units used by the task. If the requires_compatibilities is FARGATE this field is required. */
  cpu?: Pulumi.Input.t<string>,
  /** Amount (in MiB) of memory used by the task. If the requires_compatibilities is FARGATE this field is required. */
  memory?: Pulumi.Input.t<string>,
  /** Docker networking mode to use for the containers in the task. */
  networkMode?: [#none | #bridge | #awsvpc | #host],
  /** Set of launch types required by the task. */
  requiresCompatibilities?: array<string>, // TODO: narrow down type
  /** ARN of the task execution role that the Amazon ECS container agent and the Docker daemon can assume. */
  executionRoleArn?: Pulumi.Input.t<string>,
  /** ARN of IAM role that allows your Amazon ECS container task to make calls to other AWS services. */
  taskRoleArn?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("ecs") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "TaskDefinition"
