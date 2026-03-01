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
  /** Provider-specific metadata (e.g. ARN, connection string). */
  info: Pulumi.Output.t<string>,
  /** Cloud service type identifier (e.g. "dynamodb", "sqs"). */
  service: Pulumi.Output.t<string>,
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
  /** Provider-specific metadata (e.g. ARN, connection string). */
  info: string,
  /** Cloud service type identifier (e.g. "dynamodb", "sqs"). */
  service: string,
}
