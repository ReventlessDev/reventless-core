type t

@module("aws-sdk") @new
external ses: unit => t = "SES"

module SendEmailRequest = {
  type destination = {
    @as("ToAddresses") toAddresses?: array<string>,
    @as("CcAddresses") ccAddresses?: array<string>,
    @as("BccAddresses") bccAddresses?: array<string>,
  }

  type subject = {@as("Data") data: string, @as("Charset") charset?: string}
  type text = {@as("Data") data: string, @as("Charset") charset?: string}
  type body = {@as("Text") text: text}

  type message = {@as("Subject") subject: subject, @as("Body") body: body}

  type t = {
    @as("Source") source: string,
    @as("Destination") destination: destination,
    @as("Message") message: message,
  }
}

type sendEmailResponse = {@as("MessageId") messageId: string}

@send
external sendEmail: (t, ~params: SendEmailRequest.t) => AwsSdk.Request.t<sendEmailResponse> =
  "sendEmail"

let sendTextEmail = (
  t,
  ~source: string,
  ~destination: SendEmailRequest.destination,
  ~subject: string,
  ~message: string,
) =>
  sendEmail(
    t,
    ~params={
      source,
      destination,
      message: {
        SendEmailRequest.subject: {SendEmailRequest.data: subject},
        body: {text: {SendEmailRequest.data: message}},
      },
    },
  )->AwsSdk.Request.promise

module EmailIdentity = {
  type t = {arn: Pulumi.Output.t<PulumiAws.Aws.arn>, email: Pulumi.Output.t<string>}

  type args = {email: string}

  @module("@pulumi/aws") @new @scope("ses")
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "EmailIdentity"
}

module IdentityPolicy = {
  type t

  type args = {
    identity: Pulumi.Input.t<PulumiAws.Aws.arn>,
    policy: Pulumi.Input.t<Js.Json.t>,
  }

  @module("@pulumi/aws") @new @scope("ses")
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "IdentityPolicy"
}
