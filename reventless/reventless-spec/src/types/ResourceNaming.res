/**
Provider-agnostic interface for naming infrastructure resources.

Injected into extension points and tasks so they can derive unique,
valid resource names without coupling to a specific cloud provider.
*/
type operations = {
  /** Validates and sanitizes a proposed resource name to comply with provider rules. */
  validateName: string => string,
  /** Derives a URN-safe name for use in Pulumi resource URNs. */
  urnName: string => string,
}
