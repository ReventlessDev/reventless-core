/** @pulumi/pulumi/Output
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/types/Output.html
*/
type t<'a> = {}

@val @module("@pulumi/pulumi") external make: 'a => t<'a> = "output"
@send external apply: (t<'a>, 'a => 'b) => t<'b> = "apply"
@send external get: t<'a> => 'a = "get"
@send external asInput: t<'a> => Input.t<'a> = "%identity"
@send external fromInput: Input.t<'a> => t<'a> = "%identity"
@send external fromPromise: Js.Promise.t<'a> => t<'a> = "%identity"
@module("@pulumi/pulumi") @scope("Output") external isOutput: 'a => bool = "isInstance"

/** DEPRECATED: Do not use this function!  */
@send
@deprecated("Do not use this function!!!")
external promise: t<'a> => Js.Promise.t<'a> = "promise"

@send external unwrap: t<'a> => 'a = "%identity"

type unsound
@val @module("@pulumi/pulumi")
external allJst: 'a => t<unsound> = "all"
@val @module("@pulumi/pulumi")
external allDict: dict<t<'a>> => t<dict<'a>> = "all"
let allOpt: option<t<'a>> => t<option<'a>> = opt =>
  switch opt {
  | Some(output) => output->apply(a => Some(a))
  | None => None->make
  }

/** resolve all given (nested) outputs
  * Note: unwarps deeply nested outputs
  * e.g: Output.t({a: Output.t(string)}) wille result in Output.t({a: string})
  */
@val
@module("@pulumi/pulumi")
external all: array<t<'a>> => t<array<'a>> = "all"
@val @module("@pulumi/pulumi")
external all2: ((t<'a>, t<'b>)) => t<('a, 'b)> = "all"
@val @module("@pulumi/pulumi")
external all3: ((t<'a>, t<'b>, t<'c>)) => t<('a, 'b, 'c)> = "all"
@val @module("@pulumi/pulumi")
external all4: ((t<'a>, t<'b>, t<'c>, t<'d>)) => t<('a, 'b, 'c, 'd)> = "all"
@val @module("@pulumi/pulumi")
external all5: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>)) => t<('a, 'b, 'c, 'd, 'e)> = "all"
@val @module("@pulumi/pulumi")
external all6: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>, t<'f>)) => t<('a, 'b, 'c, 'd, 'e, 'f)> = "all"
@val @module("@pulumi/pulumi")
external all7: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>, t<'f>, t<'g>)) => t<(
  'a,
  'b,
  'c,
  'd,
  'e,
  'f,
  'g,
)> = "all"
@val @module("@pulumi/pulumi")
external all8: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>, t<'f>, t<'g>, t<'h>)) => t<(
  'a,
  'b,
  'c,
  'd,
  'e,
  'f,
  'g,
  'h,
)> = "all"

let map = apply

let flatMap: (t<'a>, 'a => t<'b>) => t<'b> = (m, f) => m->map(f)->unwrap

let unzip: t<('a, 'b)> => (t<'a>, t<'b>) = t => (t->apply(((a, _)) => a), t->apply(((_, b)) => b))
let unzip3: t<('a, 'b, 'c)> => (t<'a>, t<'b>, t<'c>) = t => (
  t->apply(((a, _, _)) => a),
  t->apply(((_, b, _)) => b),
  t->apply(((_, _, c)) => c),
)

let zip = all2
let zip3 = all3

/*
[@bs.set]
external optionImplXXX: t('a, option(int)) => unit = "BS_PRIVATE_NESTED_SOME_NONE"
let safeGuardOptionalOutput: t('a) => t('a) = (output) => output->optionImplXXX(None);
*/
