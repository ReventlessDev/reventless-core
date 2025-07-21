type inputs

module ResourceTransformationArgs = {
  type resource
  module Props = {
    type t<'a> = 'a
    let update: (~props: t<'a>, 'b) => 'c = (~props, obj) => {
      open Js.Obj
      ()->empty->assign(obj)->assign(props)
    }
  }

  type t<'a> = {
    resource: resource,
    _type: string,
    name: string,
    props: Props.t<'a>,
    opts: CustomResourceOptions.t,
  }
}

module ResourceTransformationResult = {
  type t = {props: inputs, opts: CustomResourceOptions.t}
}

@module("@pulumi/pulumi") @scope("runtime")
external registerStackTransformation: (
  ResourceTransformationArgs.t<'a> => option<ResourceTransformationResult.t>
) => unit = "registerStackTransformation"
