module type T = {
  [@decco]
  type t;
  type input;
  let make: input => t;
  let makeFromString: string => t;
  let toString: t => string;
  let cmp: (t, t) => int;
};
