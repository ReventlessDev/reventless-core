// The fixture app's local platform, which the stand-in runtime's tests start as
// a child process. Ports, store and accounts come from the environment.

module Platform = ReventlessLocal.Platform.Make()

module Charging = Plugin.Make(Platform)

Platform.makePlatform(~version="0.0.0-fixture", ~plugins=[module(Charging)])

Platform.startServers()
