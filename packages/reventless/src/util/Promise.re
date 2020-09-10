type t('v, 'e) = Repromise.Rejectable.t('v, 'e);
type unrejectable('v) = Repromise.Rejectable.t('v, Repromise.never);

let resolved: 'a => t('a, 'e) =
  resolvedValue => resolvedValue |> Repromise.Rejectable.resolved;

let rejected: 'e => t('a, 'e) =
  rejectedValue => rejectedValue |> Repromise.Rejectable.rejected;

let fromJs:
  (Js.Promise.error => 'e, Js.Promise.t('a)) =>
  unrejectable(Belt.Result.t('a, 'e)) =
  (errorHandler, promise) => {
    promise
    |> Repromise.Rejectable.fromJsPromise
    |> Repromise.Rejectable.map(value => Belt.Result.Ok(value))
    |> Repromise.Rejectable.catch(err =>
         Belt.Result.Error(err |> errorHandler) |> Repromise.resolved
       ) /*error => {    Js.log(error);    Belt.Result.Error("Couldn't resolve promise!") |> Repromise.resolved;  }*/;
  };
/* handle a JS-Promise with a given function and Belt.Result
 */
let handlePromise:
  (Belt.Result.t('a, 'e) => Belt.Result.t('b, 'f), Js.Promise.t('a)) =>
  unrejectable(Belt.Result.t('b, 'f)) =
  (handle, promise) => {
    promise
    |> fromJs(err => err)
    |> Repromise.Rejectable.andThen(result =>
         result |> handle |> Repromise.Rejectable.resolved
       );
  };

let all_inArray: array(t('v, 'f)) => t(array('v), 'f) =
  promises =>
    promises->Belt.List.fromArray->Repromise.Rejectable.all
    |> Repromise.Rejectable.map(resultList => resultList->Belt.List.toArray);

let all_inList: list(t('v, 'f)) => t(list('v), 'f) =
  promises => promises |> Repromise.Rejectable.all;

let map: ('a => 'b, t('a, 'e)) => t('b, 'e) =
  (mapFn, promise) => Repromise.Rejectable.map(mapFn, promise);

let toJs: t('v, 'e) => Js.Promise.t('v) =
  rejectable => rejectable |> Repromise.Rejectable.toJsPromise;

/*****************************************************************************************************
 *  EXAMPLE
 ***************************************************************************************************/
/*
 let resultHandler = result => {
   switch (result) {
   | Belt.Result.Ok(value) => Js.log2("successfully retrieved:", value)
   | Belt.Result.Error(error) => Js.log2("error on retrieve:", error)
   };
   Js.log(result);
   result;
 };

 Js.Promise.resolve("some string returned from promise")
 |> handlePromise(resultHandler);

 Js.Promise.reject(
   Invalid_argument("some error in processing, e.g. missing argument x"),
 )
 |> handlePromise(resultHandler);
 */
