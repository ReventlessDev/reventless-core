// SetShippingFee StateChangeSlice.
// Keeps one fee per shipping method; idempotent when the fee is unchanged.

@@reventless.spec

// The methods a fee is kept for, as an order names them.
@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

// The list is three entries and the command names its method as an enum, which is
// no tag to read by, so the slice reads the list whole and picks its method's fee.
@schema
type consumedEvent =
  | @readWhole ShippingFeeSet({shippingMethodId: string, fee: Reventless.Money.t})

@schema
type command =
  | @authorize(AllowRoles([Admin]))
  SetShippingFee({
      shippingMethod: shippingMethod,
      fee: Reventless.Money.t,
    })

@schema
type error = NegativeFee

// Stored under the method's name: a fee is kept per method.
@schema
type event = ShippingFeeSet({shippingMethodId: string, fee: Reventless.Money.t})
