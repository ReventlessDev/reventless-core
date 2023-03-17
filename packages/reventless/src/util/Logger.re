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
    ~stringify: bool=?,
    ~level: Level.t=?,
    string,
    'a
  ) =>
  unit =
  (~loc=?, ~map=identity, ~stringify=false, ~level=Level.default, desc, item) => {
    let tag =
      level->Level.toString
      ++ loc->Belt.Option.mapWithDefault(":", loc => "(" ++ loc ++ "):");

    let itemMapped = item->map;

    // try to stringify, use raw value if unsuccessfull
    let (descStringified, itemStringified) =
      if (stringify) {
        let itemStringified = itemMapped->Js.Json.stringifyAny;
        let descStringified =
          itemStringified->Belt.Option.mapWithDefault(
            desc ++ " [ERROR: Couldn't stringify, displaying raw value!]", _ =>
            desc
          );
        let itemStringifiedWithDefault =
          itemStringified->Belt.Option.mapWithDefault(itemMapped->logItem, i =>
            i->logItem
          );
        (descStringified, itemStringifiedWithDefault);
      } else {
        (desc, itemMapped->logItem);
      };

    switch (level) {
    | Warning => Js.Console.warn3(tag, descStringified, itemStringified)
    | Error => Js.Console.error3(tag, descStringified, itemStringified)
    | Info
    | Custom(_) => Js.Console.info3(tag, descStringified, itemStringified)

    | Debug => Js.Console.log3(tag, descStringified, itemStringified)
    };
  };

let logOutput:
  (
    ~loc: string=?,
    ~map: 'b => 'c=?,
    ~stringify: bool=?,
    ~level: Level.t=?,
    string,
    'a
  ) =>
  unit =
  (~loc=?, ~map=?, ~stringify=?, ~level=?, desc, item) =>
    if (item->Pulumi.Output.isOutput) {
      item
      ->Pulumi.Output.apply(item =>
          log(~loc?, ~map?, ~stringify?, ~level?, desc, item)
        )
      ->ignore;
    } else {
      let itemType = item->Js.typeof;
      log(
        ~loc?,
        ~map?,
        ~stringify?,
        ~level=Level.Error,
        desc
        ++ " ~}> was expected to be a Pulumi.Output.t, but is "
        ++ itemType
        ++ "!",
        item->Pulumi.Output.unwrap,
      );
    };
