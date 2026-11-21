// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module RegistrationPolicy = ReventlessGwt.Flow_GWT.DecisionStep(
  Plugin.RegistrationPolicy,
  Plugin.RegistrationPolicy_Decision,
)
module Registrations = ReventlessGwt.Flow_GWT.DecisionStep(
  Plugin.Registrations,
  Plugin.Registrations_Decision,
)

// Views
module RegistrationWindows = ReventlessGwt.Flow_GWT.ViewStep(
  Plugin.RegistrationWindows,
  Plugin.RegistrationWindows_Projection,
)

// Ways out
module CreateRegisteredPrincipal = ReventlessGwt.Flow_GWT.OutboundStep(
  Plugin.CreateRegisteredPrincipal,
  Plugin.CreateRegisteredPrincipal_Translation,
)
module SendRegistrationChallenge = ReventlessGwt.Flow_GWT.OutboundStep(
  Plugin.SendRegistrationChallenge,
  Plugin.SendRegistrationChallenge_Translation,
)

// Ways in
module CompleteRegistration = ReventlessGwt.Flow_GWT.InboundStep(
  Plugin.CompleteRegistration,
  Plugin.CompleteRegistration_Translation,
)
module SignUp = ReventlessGwt.Flow_GWT.InboundStep(Plugin.SignUp, Plugin.SignUp_Translation)

// What reacts and what decides, for `thenNothingElseReacts` and `whenSettled`.
let parts: ReventlessGwt.Flow_GWT.parts = {
  reacting: [],
  deciding: [RegistrationPolicy.deciding, Registrations.deciding],
}
