let baseName = name => (name->String.split("-"))[0]->Option.getOr(name)

module Adapter = Util_Adapter
module AdapterRuntime = Util_AdapterRuntime
module Array = Util_Array
module Error = Util_Error
module LogFormat = LogFormat
module Promise = Util_Promise
module Pulumi = Util_Pulumi
module QueryDb = Util_QueryDb
module QueryDbRuntime = Util_QueryDbRuntime
module ReadModel = Util_ReadModel
