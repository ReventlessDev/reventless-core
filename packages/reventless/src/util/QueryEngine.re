type value =
  | String(string)
  | Int(int)
  | Bool(bool);
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
  | BeginsWith;
type filterConfig = (string, comparator, value);

type query =
  (
    ~serviceName: string,
    ~key: string,
    ~value: value,
    ~filterConfigs: list(filterConfig),
    ~ascending: bool,
    ~limit: int
  ) =>
  Js.Promise.t(array(Js.Json.t));
