/*** @aws-sdk/client-resource-groups-tagging-api
  see: https://docs.aws.amazon.com/resourcegroupstagging/latest/APIReference/API_GetResources.html

  Discovers resources by tag within a region. The seed reset uses it to find the
  exact DynamoDB tables and S3 buckets belonging to a stack via the
  `reventless:environment` tag every framework resource carries — so the wipe's
  blast radius is defined by that tag, not by name globbing.

  Unlike the other clients here there is no memoised default: the caller passes a
  client so the region is explicit. `GetResources` is paginated via
  `PaginationToken` — an empty/absent token in the response means the last page.
*/
type client

module Raw = {
  type options = {region?: string}
  @module("@aws-sdk/client-resource-groups-tagging-api") @new
  external client: (~options: options=?, unit) => client = "ResourceGroupsTaggingAPIClient"
}

let client = (~region: option<string>=?, ()): client => Raw.client(~options={region: ?region}, ())

module GetResourcesCommand = {
  /*** see: https://docs.aws.amazon.com/resourcegroupstagging/latest/APIReference/API_GetResources.html */

  type t

  type tagFilter = {
    @as("Key") key: string,
    @as("Values") values?: array<string>,
  }

  type input = {
    @as("TagFilters") tagFilters?: array<tagFilter>,
    /** e.g. "dynamodb:table", "s3" — service or service:resourceType */
    @as("ResourceTypeFilters")
    resourceTypeFilters?: array<string>,
    @as("ResourcesPerPage") resourcesPerPage?: int,
    /** empty on the first call; feed back the response token until it is absent */
    @as("PaginationToken")
    paginationToken?: string,
  }

  type tag = {@as("Key") key: string, @as("Value") value: string}

  type resourceTagMapping = {
    @as("ResourceARN") resourceARN: string,
    @as("Tags") tags?: array<tag>,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("ResourceTagMappingList") resourceTagMappingList?: array<resourceTagMapping>,
    /** absent or "" on the final page */
    @as("PaginationToken")
    paginationToken?: string,
  }

  @new @module("@aws-sdk/client-resource-groups-tagging-api")
  external make: input => t = "GetResourcesCommand"

  @send external send: (client, t) => promise<output> = "send"
}
