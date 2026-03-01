/**
 * Enqueues an event for processing by a downstream component (e.g. a read model).
 *
 * - `delay` — delivery delay in seconds (0 for immediate delivery)
 * - `id` — the aggregate ID string the event belongs to
 * - `message` — the serialized event payload (JSON string)
 *
 * This function is exposed by read model `operations` so that the aggregate
 * runtime can push events without knowing the read model's infrastructure details.
 */
type enqueueEvent = (/* ~delay: */ int, /* ~id: */ string, /* ~message: */ string) => promise<unit>

/**
 * Deploy-time outputs produced when an `EventCollector` is provisioned.
 *
 * An `EventCollector` is the inbound queue of a read model — events are collected
 * here and then processed in order by the read model's projection function.
 */
type outputs = {name: string, resources: array<Adapter.resource>}
