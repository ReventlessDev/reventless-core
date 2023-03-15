module Level = {
  type nonrec t =
    | Debug
    | Info
    | Warn
    | Error
    | Custom(string);

  let toString = level =>
    switch (level) {
    | Debug => "DEBUG"
    | Info => "INFO"
    | Warn => "WARNING"
    | Error => "ERROR"
    | Custom(x) => x
    };
};

type logItem;
external logItem: 'a => logItem = "%identity";

let log:
  (~loc: string=?, ~serialize: bool=?, ~level: Level.t=?, string, 'a) => unit =
  (~loc=?, ~serialize=false, ~level=Debug, desc, item) => {
    let tag =
      level->Level.toString
      ++ loc->Belt.Option.mapWithDefault(":", loc => "(" ++ loc ++ "):");

    let item = serialize ? item->Js.Json.stringifyAny->logItem : item->logItem;

    switch (level) {
    | Warn => Js.Console.warn3(tag, desc, item)
    | Error => Js.Console.error3(tag, desc, item)
    | Info
    | Custom(_) => Js.Console.info3(tag, desc, item)

    | Debug => Js.Console.log3(tag, desc, item)
    };
  };

let logOutput:
  (
    ~loc: string=?,
    ~serialize: bool=?,
    ~level: Level.t=?,
    string,
    Pulumi.Output.t('a)
  ) =>
  unit =
  (~loc=?, ~serialize=false, ~level=Debug, desc, item) => {
    let _: Pulumi.Output.t(unit) =
      item->Pulumi.Output.apply(item =>
        log(~loc?, ~serialize, ~level, desc, item)
      );
    ();
  };
