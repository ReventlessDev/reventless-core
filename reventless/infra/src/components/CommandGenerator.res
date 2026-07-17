/**
 * Deploy-time outputs produced when a `CommandGenerator` is provisioned.
 *
 * The command generator is an internal component that translates raw JSON
 * command messages from the command topic into typed domain commands and
 * dispatches them to the aggregate handler.
 */
type outputs = {resources: array<Adapter.resource>}
