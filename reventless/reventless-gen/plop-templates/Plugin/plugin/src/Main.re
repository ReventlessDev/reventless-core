let plugin =
  ReventlessAws.Plugin.make(
    ~name=Config.pluginName,
    ~version=Config.version,
    ~heartbeatInterval=5,
    ~extensionPoints=[||],
    ~extensions=[||],
    ~aggregates=[||],
    ~readModels=[||],
    ~taskMakers=[||],
    ~scheduler=Config.scheduler,
    (),
  );
