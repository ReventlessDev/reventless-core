type client

module Raw = {
  @module("@aws-sdk/client-sesv2") @new
  external client: unit => client = "SESv2Client"
}

let clientInstance = ref(None)

let client = () => {
  switch clientInstance.contents {
  | None =>
    let client = Raw.client()
    clientInstance := Some(client)
    client
  | Some(client) => client
  }
}

module SendEmailCommand = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/sesv2/command/SendEmailCommand/ */

  type t

  type content = {
    @as("Data") data: string,
    @as("Charset") charset?: string,
  }

  type raw // FIXME: implement

  type template // FIXME: implement

  type messageBody = {
    @as("Html") html?: content,
    @as("Text") text?: content,
  }

  type nameValue = {
    @as("Name") name: string,
    @as("Value") value: string,
  }

  type message = {
    @as("Body") body: messageBody,
    @as("Subject") subject: content,
    @as("Headers") headers?: array<nameValue>,
  }

  type emailContent = {
    @as("Raw") raw?: raw,
    @as("Simple") simple?: message,
    @as("Template") template?: template,
  }

  type destination = {
    @as("ToAddresses") toAddresses?: array<string>,
    @as("CcAddresses") ccAddresses?: array<string>,
    @as("BccAddresses") bccAddresses?: array<string>,
  }

  type listManagementOptions = {
    @as("ContactListName") listName: string,
    @as("TopicName") topicName?: string,
  }

  type input = {
    @as("Content") content: emailContent,
    @as("ConfigurationSetName") configurationSetName?: string,
    @as("Destination") destination: destination,
    @as("EmailTags") emailTags?: array<nameValue>,
    @as("FeedbackForwardingEmailAddress") feedbackForwardingEmailAddress?: string,
    @as("FeedbackForwardingEmailAddressIdentityArn")
    feedbackForwardingEmailAddressIdentityArn?: string,
    @as("FromEmailAddress") fromEmailAddress?: string,
    @as("FromEmailAddressIdentityArn") fromEmailAddressIdentityArn?: string,
    @as("ListManagementOptions") listManagementOptions?: listManagementOptions,
    @as("ReplyToAddresses") replyToAddresses?: array<string>,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("MessageId") messageId?: string,
  }

  @new @module("@aws-sdk/client-sesv2")
  external make: input => t = "SendEmailCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

let sendTextEmail = (
  ~source: string,
  ~destination: SendEmailCommand.destination,
  ~subject: string,
  ~message: string,
) => {
  SendEmailCommand.fromEmailAddress: source,
  destination,
  content: {
    simple: {
      subject: {data: subject},
      body: {
        text: {data: message},
      },
    },
  },
}
