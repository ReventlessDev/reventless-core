/**aws-sdk/ecs
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/ecs/
**/
type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-ecs") @new
  external client: (options, unit) => client = "ECSClient"
}

let instance = ref(None)

let client = () =>
  switch instance.contents {
  | None =>
    let client = Raw.client(
      {
        maxAttempts: 3,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 1000,
          requestTimeout: 5000,
        }),
      },
      (),
    )
    instance := Some(client)
    client
  | Some(client) => client
  }

type containerOverride = {
  /** name of the container that receives the override. This parameter is required if any override is specified. */
  name?: string,
  /** command to send to the container that overrides the default command from the Docker image */
  command?: array<string>,
  /** environment variables to send to the container. You can add new environment variables, which are added to the container at launch, or you can override the existing environment variables from the Docker image or the task definition. You must also specify a container name. */
  environment?: dict<string>,
}

type taskOverride = {containerOverrides?: array<containerOverride>}

type awsVpcConfiguration = {subnets: array<string>}

type networkConfiguration = {awsvpcConfiguration?: awsVpcConfiguration}

module RunTaskCommand = {
  type t

  type launchType = [#EC2 | #FARGATE | #EXTERNAL]

  type input = {
    /** The family and revision (family:revision) or full ARN of the task definition to run.
    If a revision is not specified, the latest ACTIVE revision is used. */
    taskDefinition: string,
    /** infrastructure on which to run your standalone task. */
    launchType?: launchType,
    /** short name or full Amazon Resource Name (ARN) of the cluster on which to run your task. */
    cluster?: string,
    /** network configuration for the task. This parameter is required for task definitions
    that use the awsvpc network mode to receive their own elastic network interface, and it is not supported for other network modes. */
    networkConfiguration?: networkConfiguration,
    /** number of instantiations of the specified task to place on your cluster. */
    count?: int,
    /**    list of container overrides in JSON format that specify the name of a container in the specified task definition and the overrides it should receive. */
    overrides?: taskOverride,
  }

  type task = {taskArn: string}

  type failure = {
    arn: string,
    reason: string,
    detail: string,
  }

  type output = {
    tasks: array<task>,
    failures: array<failure>,
  }

  @new @module("@aws-sdk/client-ecs")
  external make: input => t = "RunTaskCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}
