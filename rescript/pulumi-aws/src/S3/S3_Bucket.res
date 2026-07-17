/** @pulumi/aws/s3/Bucket
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucket
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  region: Pulumi.Output.t<string>,
  bucket: Pulumi.Output.t<string>,
  bucketRegionalDomainName: Pulumi.Output.t<string>,
}

type corsRule = {
  allowedHeaders: array<string>,
  allowedMethods: array<string>,
  allowedOrigins: array<string>,
  exposeHeaders: array<string>,
  maxAgeSeconds: int,
}

type corsRules = array<corsRule>

type lifecycleRuleExpiration = {
  date: string,
  days: int,
  expiredObjectDeleteMarker: bool,
}

type lifecycleRuleNoncurrentVersionExpiration = {days: int}

type lifecycleRuleNoncurrentVersionTransition = {
  days: int,
  storageClass: string,
}

type lifecycleRuleTransition = {
  date: string,
  days: int,
  storageClass: string,
}

type lifecycleRule = {
  abortIncompleteMultipartUploadDays: int,
  enabled: bool,
  expiration: lifecycleRuleExpiration,
  id: string,
  noncurrentVersionExpiration: lifecycleRuleNoncurrentVersionExpiration,
  noncurrentVersionTransitions: array<lifecycleRuleNoncurrentVersionTransition>,
  prefix: string,
  tags: Aws.tags,
  transitions: array<lifecycleRuleTransition>,
}

type lifecycleRules = array<lifecycleRule>

type logging = {
  targetBucket: string,
  targetPrefix: string,
}

type loggings = array<logging>

type objectLockConfigurationRule = {
  days: int,
  mode: string,
  years: int,
}

type objectLockConfiguration = {
  objectLockEnabled: bool,
  rule: objectLockConfigurationRule,
}

type replicationConfigurationRuleOwner = {owner: string}

type replicationConfigurationRuleDestination = {
  accessControlTranslation: replicationConfigurationRuleOwner,
  accountId: string,
  bucket: string,
  replicaKmsKeyId: string,
  storageClass: string,
}

type replicationConfigurationFilter = {
  prefix: string,
  tags: Aws.tags,
}

type replicationConfigurationRuleSourceSelectionCriteriaSseKmsEncryptedObjects = {enabled: bool}

type replicationConfigurationRuleSourceSelectionCriteria = {
  sseKmsEncryptedObjects: replicationConfigurationRuleSourceSelectionCriteriaSseKmsEncryptedObjects,
}

type replicationConfigurationRule = {
  destination: replicationConfigurationRuleDestination,
  filter: replicationConfigurationFilter,
  id: string,
  prefix: string,
  priority: int,
  sourceSelectionCriteria: replicationConfigurationRuleSourceSelectionCriteria,
  status: string,
}

type replicationConfiguration = {
  role: string,
  rules: array<replicationConfigurationRule>,
}

type serverSideEncryptionConfigurationRuleApplyServerSideEncryptionByDefault = {
  kmsMasterKeyId: string,
  sseAlgorithm: string,
}

type serverSideEncryptionConfigurationRule = {
  applyServerSideEncryptionByDefault: serverSideEncryptionConfigurationRuleApplyServerSideEncryptionByDefault,
}

type serverSideEncryptionConfiguration = {rule: serverSideEncryptionConfigurationRule}

type versioning = {
  enabled: bool,
  mfaDelete: bool,
}

type website = {
  errorDocument: string,
  indexDocument: string,
  redirectAllRequestsTo: string,
  routingRules: string,
}

type acl =
  | @as("private") Private
  | @as("public-read") PublicRead
  | @as("public-read-write") PublicReadWrite
  | @as("aws-exec-read") AwsExecRead
  | @as("authenticated-read") AuthenticatedRead
  | @as("log-delivery-write") LogDeliveryWrite

type args = {
  accelerationStatus?: Pulumi.Input.t<string>,
  acl?: Pulumi.Input.t<acl>,
  arn?: Pulumi.Input.t<string>,
  bucket?: Pulumi.Input.t<string>,
  bucketPrefix?: Pulumi.Input.t<string>,
  corsRules?: Pulumi.Input.t<corsRules>,
  forceDestroy?: Pulumi.Input.t<bool>,
  hosteZoneId?: Pulumi.Input.t<string>,
  lifecycleRules?: Pulumi.Input.t<lifecycleRules>,
  loggings?: Pulumi.Input.t<loggings>,
  objectLockConfiguration?: Pulumi.Input.t<objectLockConfiguration>,
  policy?: Pulumi.Input.t<string>,
  region?: Pulumi.Input.t<string>,
  replicationConfiguration?: Pulumi.Input.t<replicationConfiguration>,
  requestPayer?: Pulumi.Input.t<string>,
  serverSideEncryptionConfiguration?: Pulumi.Input.t<serverSideEncryptionConfiguration>,
  tags?: Pulumi.Input.t<Aws.tags>,
  versioning?: Pulumi.Input.t<versioning>,
  website?: Pulumi.Input.t<website>,
  websiteDomain?: Pulumi.Input.t<string>,
  websiteEndpoint?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Bucket"

type s3Event =
  | @as("*") All
  | Put
  | Post
  | Copy
  | CompleteMultipartUpload

type subscriptionArgs = {
  event: s3Event,
  filterPrefix?: string,
  filterSuffix?: string,
}

type bucket = {name: string, ownerIdentity: Lambda.userIdentity, arn: string}
type object = {key: string, size: int, eTag: string, versionId: string, sequencer: string}
type s3Record = {
  s3SchemaVersion: string,
  configurationId: string,
  bucket: bucket,
  object: object,
}
type requestParameters = {sourceIPAddress: string}

type responseElements = {
  @as("x-amz-request-id") xAmzRequestId: string,
  @as("x-amz-id-2") xAmzId2: string,
}

type record = {
  eventVersion: string,
  eventSource: string,
  awsRegion: string,
  eventTime: string,
  eventName: string,
  userIdentity: Lambda.userIdentity,
  requestParameters: requestParameters,
  responseElements: responseElements,
  s3: s3Record,
}

external asRecord: Lambda.CallbackFunction.record => record = "%identity"

type event = {@as("Records") records: array<record>}

type subscription = {
  name: string,
  bucket: t,
  handler: Lambda.CallbackFunction.t,
  args: subscriptionArgs,
  opts: option<Pulumi.CustomResourceOptions.t>,
}

@send
external onObjectCreated: (
  t,
  ~name: string,
  ~handler: Lambda.CallbackFunction.t,
  ~args: subscriptionArgs=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => subscription = "onObjectCreated"

@send
external onObjectRemoved: (
  t,
  ~name: string,
  ~handler: Lambda.CallbackFunction.t,
  ~args: subscriptionArgs=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => subscription = "onObjectRemoved"
