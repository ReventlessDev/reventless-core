module Id = Id.String;

open PluginSpec;

[@decco]
type status =
  | Connected
  | Disconnected
  | Inactive;

[@decco]
type state = {
  name,
  version,
  eventCollector: string,
  extensionPoints: array(extensionPointDefinition),
  extensionPointNames: array(string),
  extensionNames: array(string),
  extensions: array(extensionDefinition),
  status,
  statusChange: Message.statusChange,
};

type queryResult = {
  id: string,
  name,
  version,
  eventCollector: string,
  extensionPoints: array(extensionPointDefinition),
  extensionPointNames: array(string),
  extensionNames: array(string),
  extensions: array(extensionDefinition),
  status,
};

let name = "Plugin";

let resolveIdConfigs = [];
let resolveIdsConfigs = [];

let subIdConfig = None;

let indexes = [];
