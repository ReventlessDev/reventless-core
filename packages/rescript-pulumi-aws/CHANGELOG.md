# Changelog of rescript-pulumi-aws

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 [Unreleased]

### Added

- EC2: VPCEndpoint
- Aws: getRegion

### Changed

- Aws: split up into separate modules Aws_Aws, Aws_Common
- EC2.VPCEndpoint.Args: type VpcEndpointType explicitly instead of just string

### Deprecated

- ..
- ..

### Removed

- ..
- ..

### Fixed

- EC2: fixed handling of optional labeled arguments in make functions
- ..

### Security

- ..
- ..

## 0.0.1

### Added

- Appsync: DataSource, Function, GraphQLApi, Resolver, Resolver_Templates
- Aws: common types for arn & tags, AvailabilityZone
- Cognito: IdentityPool, IdentityPoolRoleAttachment, UserGroup, UserPool, UserPoolClient
- DynamoDb: Table
- EC2: DefaultSecurityGroup, Eip, InternetGateway, NatGateway, RouteTable, RouteTableAssociation, SecurityGroup, Subnet, VPC
- IAM: getPolicyDocument, Policy, Role, RolePolicy
- Kinesis: Stream
- Lambda: CallbackFunction, Permission
- S3: Bucket
- SNS: Topic, TopicSubscription
- SQS: Queue, QueuePolicy
