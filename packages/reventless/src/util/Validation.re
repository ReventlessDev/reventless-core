type error = string;

type t('a, 'b) =
  | Success('a)
  | Successes(array('a))
  | Failure('b)
  | Failures(array('b));

type async('a, 'b) = Js.Promise.t(t('a, 'b));

open Belt.Array;

let merge: (t('a, 'b), t('a, 'b)) => t('a, 'b) =
  (v1, v2) =>
    switch (v1, v2) {
    | (Successes(as1), Successes(as2)) => Successes(as1->concat(as2))
    | (Successes(as1), Success(a2)) => Successes(as1->concat([|a2|]))
    | (Success(a1), Successes(as2)) => Successes([|a1|]->concat(as2))
    | (Success(a1), Success(a2)) => Successes([|a1, a2|])
    | (Success(_), Failure(b2)) => Failure(b2)
    | (Success(_), Failures(bs2)) => Failures(bs2)
    | (Successes(_), Failure(b2)) => Failure(b2)
    | (Successes(_), Failures(bs2)) => Failures(bs2)
    | (Failure(b1), Success(_)) => Failure(b1)
    | (Failure(b1), Successes(_)) => Failure(b1)
    | (Failures(bs1), Success(_)) => Failures(bs1)
    | (Failures(bs1), Successes(_)) => Failures(bs1)
    | (Failure(b1), Failure(b2)) => Failures([|b1, b2|])
    | (Failure(b1), Failures(bs2)) => Failures([|b1|]->concat(bs2))
    | (Failures(bs1), Failure(b2)) => Failures(bs1->concat([|b2|]))
    | (Failures(bs1), Failures(bs2)) => Failures(bs1->concat(bs2))
    };

let defaultErrorHandler = err => {
  Js.log(err);
  Failure("Couldn't resolve promise.");
};

let (<+>) = merge;

let mergeAsync:
  (async('a, 'b), async('a, 'b), Js.Promise.error => t('a, 'b)) =>
  async('a, 'b) =
  (a1, a2, handle) =>
    Js.Promise.all2((a1, a2))
    |> Js.Promise.then_(((v1, v2)) => Js.Promise.resolve(v1 <+> v2))
    |> Js.Promise.catch(err => Js.Promise.resolve(err |> handle));

let (<?>) = (a1, a2) => mergeAsync(a1, a2, defaultErrorHandler);

let mergeAsyncLeft:
  (async('a, 'b), t('a, 'b), Js.Promise.error => t('a, 'b)) =>
  async('a, 'b) =
  (a1, v2, handler) => mergeAsync(a1, Js.Promise.resolve(v2), handler);

let (<?+>) = (a1, v2) => mergeAsyncLeft(a1, v2, defaultErrorHandler);

let mergeAsyncRight:
  (t('a, 'b), async('a, 'b), Js.Promise.error => t('a, 'b)) =>
  async('a, 'b) =
  (v1, a2, handler) => mergeAsync(Js.Promise.resolve(v1), a2, handler);

let (<+?>) = (v1, a2) => mergeAsyncRight(v1, a2, defaultErrorHandler);

open Belt.Result;

let toResult =
  fun
  | Success(s) => Ok([|s|])
  | Successes(ss) => Ok(ss)
  | Failure(f) => Error([|f|])
  | Failures(fs) => Error(fs);