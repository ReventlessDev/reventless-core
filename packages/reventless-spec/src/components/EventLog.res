type append<'id, 'event> = (int, 'id, array<'event>) => promise<Belt.Result.t<unit, string>>
type replay<'id, 'event> = 'id => promise<array<'event>>
