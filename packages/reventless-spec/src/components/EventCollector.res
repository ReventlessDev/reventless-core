type enqueueEvent = (
  /* ~delay: */ int,
  /* ~id: */ string,
  /* ~message: */ string,
) => Js.Promise.t<unit>
