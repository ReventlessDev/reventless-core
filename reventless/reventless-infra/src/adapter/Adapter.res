/** Platform-agnostic metadata for a resource's structural role. */
type resourceInfo =
  | StorageKeys({partitionKey: string, sortKey: option<string>})
  | StreamSource({sourceUrn: string})
  | ApiResolver({typeName: string, fieldName: string})
  | NoInfo

/**
A deploy-time infrastructure resource with all fields wrapped in `Pulumi.Output.t`.

At deploy time (Pulumi program) resource identifiers are not yet known — they
exist as `Output.t` promises that resolve once the resource is provisioned.
Use `resolvedResource` at runtime (inside Lambda handlers) once values are available.
*/
type resource = {
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  urn: Pulumi.Output.t<string>,
  /** Typed metadata describing the resource's structural characteristics. */
  resourceInfo: Pulumi.Output.t<resourceInfo>,
  /** Cloud service type identifier (e.g. "aws:DynamoDb", "aws:Lambda"). */
  service: Pulumi.Output.t<string>,
  /** Functional role within a component (e.g. "eventLog", "commandTopic", "queryDb"). */
  role: Pulumi.Output.t<string>,
  /** Cloud region (e.g. "eu-west-1", "local"). */
  region: Pulumi.Output.t<string>,
  /** Full cloud resource type (e.g. "aws:dynamodb:Table", "aws:lambda:Function"). */
  resourceType: Pulumi.Output.t<string>,
  /** Key infrastructure configuration properties (informational, not used at runtime). */
  configuration: Pulumi.Output.t<dict<string>>,
}

/** Create a deploy-time resource with sensible defaults for metadata fields. */
let make = (
  ~name,
  ~id,
  ~urn,
  ~service,
  ~resourceInfo=NoInfo->Pulumi.Output.make,
  ~role=""->Pulumi.Output.make,
  ~region=""->Pulumi.Output.make,
  ~resourceType=""->Pulumi.Output.make,
  ~configuration=Dict.make()->Pulumi.Output.make,
): resource => {
  name,
  id,
  urn,
  resourceInfo,
  service,
  role,
  region,
  resourceType,
  configuration,
}

/** A named dictionary of deploy-time infrastructure resources. */
type resources = dict<resource>

/**
A runtime infrastructure resource with all fields resolved to plain strings.

Passed to runtime operations (e.g. `Scheduler.operations`) that run inside
Lambda handlers, where `Pulumi.Output.t` values have already been resolved
from environment variables or SSM parameters.
*/
type resolvedResource = {
  name: string,
  id: string,
  urn: string,
  /** Typed metadata describing the resource's structural characteristics. */
  resourceInfo: resourceInfo,
  /** Cloud service type identifier (e.g. "aws:DynamoDb", "aws:Lambda"). */
  service: string,
  /** Functional role within a component (e.g. "eventLog", "commandTopic", "queryDb"). */
  role: string,
  /** Cloud region (e.g. "eu-west-1", "local"). */
  region: string,
  /** Full cloud resource type (e.g. "aws:dynamodb:Table", "aws:lambda:Function"). */
  resourceType: string,
  /** Key infrastructure configuration properties (informational, not used at runtime). */
  configuration: dict<string>,
}
