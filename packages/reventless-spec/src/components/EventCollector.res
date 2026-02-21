type enqueueEvent = (/* ~delay: */ int, /* ~id: */ string, /* ~message: */ string) => promise<unit>
type outputs = {name: string, resources: array<Adapter.resource>}
