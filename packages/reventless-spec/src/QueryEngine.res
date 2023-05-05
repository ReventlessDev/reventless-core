type value =
  | String(string)
  | Int(int)
  | Bool(bool)
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
type filterConfig = (string, comparator, value)

type query = (
  ~viewName: string,
  ~key: string=?,
  ~id: value,
  ~filterConfigs: array<filterConfig>=?,
  ~ascending: bool=?,
  ~limit: int=?,
  unit,
) => Js.Promise.t<array<Js.Json.t>>

type scan = (
  ~viewName: string,
  ~filterConfigs: array<filterConfig>,
  ~limit: int,
) => Js.Promise.t<array<Js.Json.t>>

type t = {
  scan: scan,
  query: query,
}
