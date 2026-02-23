type protocol = | @as("tcp") TCP | @as("udp") UDP
type portMapping = {containerPort?: int, hostPort?: int, protocol?: protocol}
type keyValuePair = {name: string, value: string}
type repositoryCredentials = {credentialsParameter: string}

type secret = {
  name: string,
  /** secret to expose to the container. The supported values are either the full ARN of the
   *  AWS Secrets Manager secret or the full ARN of the parameter in the AWS Systems Manager
   *  Parameter Store */
  valueFrom: string,
}

type logOptions = {
  @as("awslogs-create-group") awslogsCreateGroup: bool,
  @as("awslogs-group") awslogsGroup: string,
  @as("awslogs-region") awslogsRegion: string,
  @as("awslogs-stream-prefix") awslogsStreamPrefix: string,
}

type logConfiguration = {logDriver: string, options?: logOptions}

type ulimitName = [
  | #core
  | #cpu
  | #data
  | #fsize
  | #locks
  | #memlock
  | #msgqueue
  | #nice
  | #nofile
  | #nproc
  | #rss
  | #rtprio
  | #rttime
  | #sigpending
  | #stack
]
type ulimit = {
  name: ulimitName,
  hardLimit: int,
  softLimit: int,
}

type containerDefinition = {
  name: string,
  cpu?: int,
  environment?: array<keyValuePair>,
  essential?: bool,
  image?: string,
  logConfiguration?: logConfiguration,
  memory?: int,
  portMappings?: array<portMapping>,
  repositoryCredentials?: repositoryCredentials,
  secrets?: array<secret>,
  ulimits?: array<ulimit>,
}
