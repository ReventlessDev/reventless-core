import * as pulumi from "@pulumi/pulumi";

class Component extends pulumi.ComponentResource {
  constructor(componentType, name, construct, opts, param1, param2, param3) {
    super("reventless:" + componentType, name, {}, opts);
    construct(this, name, param1, param2, param3);
  };
}

export default Component;
