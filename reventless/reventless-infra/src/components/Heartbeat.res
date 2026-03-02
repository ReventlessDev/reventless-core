/**
 * Deploy-time outputs produced when a `Heartbeat` component is provisioned.
 *
 * The heartbeat is an internal health-check component that periodically fires
 * to verify that the plugin's Lambda handlers are reachable and warm.
 */
type outputs = {name: string, resources: array<Adapter.resource>}
