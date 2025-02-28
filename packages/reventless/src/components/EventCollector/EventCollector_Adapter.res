type channelMaker<'callbackEvent, 'context> = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
) => EventCollector.channel<'callbackEvent, 'context>

module type Channel = {
  type callbackEvent
  let make: channelMaker<callbackEvent, 'context>
}
