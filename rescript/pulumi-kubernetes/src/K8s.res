/** @pulumi/kubernetes umbrella module.

  Groups every bound API group under one namespace so callers can
  `open PulumiKubernetes` and reach `K8s.Provider`, `K8s.Core.Namespace`,
  `K8s.Apps.Deployment`, etc.
*/
module Provider = K8s_Provider
module Meta = Meta
module Core = Core
module Apps = Apps
module Batch = Batch
module Rbac = Rbac
module Networking = Networking
module ApiExtensions = ApiExtensions
module Helm = Helm
module Yaml = Yaml
