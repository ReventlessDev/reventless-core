type outputs = {"name": string, "resources": array<Adapter.resource>}

type enqueueEvent = (
  . /* ~delay: */ int,
  /* ~id: */ string,
  /* ~message: */ string,
) => Js.Promise.t<unit>
