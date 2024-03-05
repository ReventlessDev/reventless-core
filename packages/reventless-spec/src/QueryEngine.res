type value =
  | String(string)
  | Int(int)
  | Bool(bool)

module Filter = {
  type comparator =
    | Equal
    | Unequal
    | LessOrEqual
    | Less
    | GreaterOrEqual
    | Greater
    | Exists
    | NotExists
    | Contains
    | NotContains
    | BeginsWith
  type config = (string, comparator, value)
}

module SubId = {
  type comparator =
    | Equal
    | Unequal
    | LessOrEqual
    | Less
    | GreaterOrEqual
    | Greater
    | BeginsWith
  type config = (string, comparator, value)
}

type query = (
  ~readModelName: string,
  ~key: string=?,
  ~id: value,
  ~subIdConfig: SubId.config=?,
  ~filterConfigs: array<Filter.config>=?,
  ~ascending: bool=?,
  ~limit: int=?,
  unit,
) => Js.Promise.t<array<Js.Json.t>>

type scan = (
  ~readModelName: string,
  ~filterConfigs: array<Filter.config>,
  ~limit: int,
) => Js.Promise.t<array<Js.Json.t>>

type t = {
  scan: scan,
  query: query,
}
