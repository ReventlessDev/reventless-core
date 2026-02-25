// Provider-agnostic interface for resource naming operations

type operations = {
  validateName: string => string,
  urnName: string => string,
}
