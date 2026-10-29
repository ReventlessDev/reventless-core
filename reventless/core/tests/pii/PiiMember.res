// Fixture: a spec whose event and command mark personal fields with `@pii`.

@@reventless.spec("PiiMember")

@schema
type event =
  | MemberJoined({
      @owner memberId: string,
      @pii name: string,
      @pii bio?: string,
      @pii nickname: option<string>,
      @pii address: Reventless.Email.t,
      @pii({subject: "memberId"}) @storageRef("photos") photo: string,
    })
  | InvitationSent({invitationId: string, @pii("invitationId") invitee: Reventless.Email.t})

@schema
type command = Join({@owner memberId: string, @pii name: string, @pii address: Reventless.Email.t})
