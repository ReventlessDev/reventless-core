type t

@module("aws-sdk") @new external ses: unit => t = "SES"

module SendEmailRequest = {
  type t

  module Destination = {
    type t

    @obj
    external make: (
      ~_ToAddresses: array<string>=?,
      ~_CcAddresses: array<string>=?,
      ~_BccAddresses: array<string>=?,
      unit,
    ) => t = ""
  }

  module Message = {
    type t

    module Subject = {
      type t

      @obj
      external make: (~_Data: string, ~_Charset: string=?, unit) => t = ""
    }

    module Body = {
      module Text = {
        type t

        @obj
        external make: (~_Data: string, ~_Charset: string=?, unit) => t = ""
      }
      type t

      @obj external make: (~_Text: Text.t) => t = ""
    }

    @obj external make: (~_Subject: Subject.t, ~_Body: Body.t) => t = ""
  }

  @obj
  external make: (~_Source: string, ~_Destination: Destination.t, ~_Message: Message.t) => t = ""
}

module SendEmailResponse = {
  type t = {"MessageId": string}
}

@send
external sendEmail: (t, ~params: SendEmailRequest.t) => AwsSdk.Request.t<SendEmailResponse.t> =
  "sendEmail"

let sendTextEmail = (
  t,
  ~source: string,
  ~destination: SendEmailRequest.Destination.t,
  ~subject: string,
  ~message: string,
) =>
  sendEmail(
    t,
    ~params=SendEmailRequest.make(
      ~_Source=source,
      ~_Destination=destination,
      ~_Message=SendEmailRequest.Message.make(
        ~_Subject=SendEmailRequest.Message.Subject.make(~_Data=subject, ()),
        ~_Body=SendEmailRequest.Message.Body.make(
          ~_Text=SendEmailRequest.Message.Body.Text.make(~_Data=message, ()),
        ),
      ),
    ),
  )->AwsSdk.Request.promise

module EmailIdentity = {
  type t = {"arn": Pulumi.Output.t<PulumiAws.Aws.arn>, "email": Pulumi.Output.t<string>}

  module Args = {
    type t

    @obj external make: (~email: string) => t = ""
  }

  @module("@pulumi/aws") @new @scope("ses")
  external make: (
    ~name: string,
    ~args: Args.t,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit,
  ) => t = "EmailIdentity"
}

module IdentityPolicy = {
  type t

  module Args = {
    type t

    @obj
    external make: (
      ~identity: Pulumi.Input.t<PulumiAws.Aws.arn>,
      ~policy: Pulumi.Input.t<Js.Json.t>,
    ) => t = ""
  }

  @module("@pulumi/aws") @new @scope("ses")
  external make: (
    ~name: string,
    ~args: Args.t,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit,
  ) => t = "IdentityPolicy"
}
