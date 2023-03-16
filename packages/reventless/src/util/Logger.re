module Level = {
  type nonrec t =
    | Debug
    | Info
    | Warning
    | Error
    | Custom(string);

  let toString = level =>
    switch (level) {
    | Debug => "DEBUG"
    | Info => "INFO"
    | Warning => "WARNING"
    | Error => "ERROR"
    | Custom(x) => x
    };

  let default = Debug;
};

type logItem;
external logItem: 'a => logItem = "%identity";
external identity: 'a => 'a = "%identity";

let log:
  (
    ~loc: string=?,
    ~map: 'a => 'b=?,
    ~serialize: bool=?,
    ~level: Level.t=?,
    string,
    'a
  ) =>
  unit =
  (~loc=?, ~map=identity, ~serialize=false, ~level=Level.default, desc, item) => {
    let tag =
      level->Level.toString
      ++ loc->Belt.Option.mapWithDefault(":", loc => "(" ++ loc ++ "):");

    let item =
      serialize
        ? item->map->Js.Json.stringifyAny->logItem : item->map->logItem;

    switch (level) {
    | Warning => Js.Console.warn3(tag, desc, item)
    | Error => Js.Console.error3(tag, desc, item)
    | Info
    | Custom(_) => Js.Console.info3(tag, desc, item)

    | Debug => Js.Console.log3(tag, desc, item)
    };
  };

let logOutput:
  (
    ~loc: string=?,
    ~map: 'a => 'b=?,
    ~serialize: bool=?,
    ~level: Level.t=?,
    string,
    Pulumi.Output.t('a)
  ) =>
  unit =
  (~loc=?, ~map=?, ~serialize=?, ~level=?, desc, item) => {
    let _: Pulumi.Output.t(unit) =
      item->Pulumi.Output.apply(item =>
        log(~loc?, ~map?, ~serialize?, ~level?, desc, item)
      );
    ();
  };
