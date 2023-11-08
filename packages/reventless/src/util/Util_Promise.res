type result<'a> = {status: string, value: option<'a>, reason: option<Js.Promise.error>}

let filterRejected = results =>
  results
  ->Belt.Array.mapWithIndex((idx, result) => (idx, result))
  ->Belt.Array.keep(((_, result)) => result.status == "rejected")
  ->Belt.Array.map(((idx, result)) => (
    idx,
    result.reason
    ->Belt.Option.map(reason => (reason->Util_Error.ofPromise).message)
    ->Belt.Option.getWithDefault("Unknown error"),
  ))

@ocaml.doc(
  " https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/allSettled "
)
@val
@scope("Promise")
external allSettled: array<Js.Promise.t<'a>> => Js.Promise.t<array<result<'a>>> = "allSettled"

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
  let res = ref((. _result) => ())
  let rej = ref((. _exn) => ())
  let promise = Js.Promise.make((~resolve, ~reject) => {
    res := resolve
    rej := reject
  })
  (promise, res.contents, rej.contents)
}

let onEndHandler = async (flush, resolve) => {
  let _ = switch await flush() {
  | _res => resolve(. ())
  | exception Js.Exn.Error(e) => Js.log2(__LOC__, e)
  }
}

let finishTimeout = timeout => {
  let (promise, resolve, _reject) = make()
  let _ = Js.Global.setTimeout(() => resolve(. ()), timeout)
  promise
}

let finishRandomTimeout = (min, max) => {
  Js.Math.random_int(min, max)->finishTimeout
}
