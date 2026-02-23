type result<'a> = {status: string, value: option<'a>, reason: option<exn>}

let filterRejected = results =>
  results
  ->Array.mapWithIndex((result, idx) => (idx, result))
  ->Array.filter(((_, result)) => result.status == "rejected")
  ->Array.map(((idx, result)) => (
    idx,
    result.reason
    ->Option.flatMap(reason => reason->JsExn.fromException)
    ->Option.flatMap(exn => exn->JsExn.message)
    ->Option.getOr("Unknown error"),
  ))

@ocaml.doc(
  " https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/allSettled "
)
@val
@scope("Promise")
external allSettled: array<promise<'a>> => promise<array<result<'a>>> = "allSettled"

let map: (promise<'a>, 'a => 'b, exn => 'b) => promise<'b> = async (p, mapOk, mapExn) =>
  switch await p {
  | a => a->mapOk
  | exception e => e->mapExn
  }

let mapOk: (promise<'a>, 'a => 'b) => promise<'b> = async (p, mapOk) =>
  switch await p {
  | a => a->mapOk
  }

let mapExn: (promise<'a>, 'exn => 'b) => promise<'b> = async (p, mapExn) =>
  switch await p {
  | a => a
  | exception e => e->mapExn
  }

let toUnit: promise<'a> => promise<unit> = p => p->mapOk(ignore)

let make = () => {
  let res = ref(_result => ())
  let rej = ref(_exn => ())
  let promise = Promise.make((resolve, reject) => {
    res := resolve
    rej := reject
  })
  (promise, res.contents, rej.contents)
}

let onEndHandler = async (flush, resolve) => {
  let _ = switch await flush() {
  | _res => resolve()
  | exception JsExn(e) => Console.log2(__LOC__, e)
  }
}

let finishTimeout = timeout => {
  let (promise, resolve, _reject) = make()
  let _ = setTimeout(() => resolve(), timeout)
  promise
}

let finishRandomTimeout = (min, max) => {
  Math.Int.random(min, max)->finishTimeout
}
