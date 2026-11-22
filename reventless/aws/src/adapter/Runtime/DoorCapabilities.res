// What the command function hands a door (an inbound translation): unguessable
// material, the stash where a door declares one, and the deployment's starting
// state for self-service roles. Nothing that sends, makes an account or looks an
// address up: this function has no grant for those, and a door declaring one is
// refused at deploy.
//
// Read per call, so a function whose configuration is updated needs no cold
// start to see it.

let capabilities = (): Reventless.Capabilities.t => {
  ...Reventless.Capabilities.none,
  secrets: ReventlessCore.Secrets_Node_Backend.provider,
  stash: Stash_DynamoDb_Backend.provider(
    ~tableName=NodeProcess.env->Dict.get("STASH_TABLE")->Option.getOr(""),
  ),
  selfRegistrationInitially: AwsSelfRegistration.initially(),
}
