module type T = {
  [@decco]
  type t;
  type input;
  let make: input => t;
  let makeFromString: string => t;
  let toString: t => string;
  let cmp: (t, t) => int;
};

module String: T = {
  [@decco]
  type t = string;
  type input = string;
  let make = str => str;
  external makeFromString: string => t = "%identity";
  let toString = t => t;
  let cmp = String.compare;
};
