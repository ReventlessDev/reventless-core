// AUTO-GENERATED from ISO 4217 (published 2026-01-01) — do not edit.
// Run `pnpm run generate:currency`, or see `scripts/GenerateCurrency.res` to
// change which codes are admitted or to update the source table first.

/**
A currency, closed to the 10 codes this framework admits today.

## Why a type and not a three-letter string

A string field invites `"eur"` beside `"EUR"`, and two spellings of one
currency is a class of bug that reads as a data problem long after it became a
correctness problem — the values are present, and they simply never match. A
closed type makes the second spelling unwritable.

## Why generated, and why a curated set

Generation buys the property that makes this type worth having: `exponent` comes
from the *same* source as the codes, so it cannot drift from them (1×0, 9×2 decimal
places across the set). That is what lets `Money` derive how many decimals an
amount may carry instead of hardcoding two, and therefore what makes it correct
for JPY without anyone remembering that JPY is special.

The set is curated because the whole table is not a choice anyone makes: a picker
holding 165 codes asks a person to find theirs in a list nobody reads, and a
domain that deals in ten does not become more correct for admitting the other 155.

Every one of those is written out below, commented, in each of the four blocks
that mention a code — so admitting one is uncommenting four lines, or adding it
to `active` in `scripts/GenerateCurrency.res` and regenerating. What a curated
list used to risk was a framework release to fix someone else's compile error;
keeping the rest in the file is what buys that back.

## What is deliberately absent

The 13 entries ISO lists with no minor unit at all: the precious metals
(XAG, XAU, XPD, XPT), the bond market units (XBA, XBB, XBC, XBD), the accounting
units (XDR, XSU, XUA), the testing code XTS, and the "no currency" sentinel
XXX. Each would make `exponent` partial, and a weight of gold is not an amount
of money. Those are absent from the dormant list too — the standard's own table
draws that line, so it is not a curated opinion after all.

## The wire form

A payload-less variant, so the stored and transmitted form is the three-letter
code itself — `{"amount": 10.5, "currency": "EUR"}`. Standard at the boundary,
a checked type in the domain.
*/
@schema
type t =
  | /** Australian Dollar */ AUD
  | /** Canadian Dollar */ CAD
  | /** Swiss Franc */ CHF
  | /** Yuan Renminbi */ CNY
  | /** Euro */ EUR
  | /** Pound Sterling */ GBP
  | /** Yen */ JPY
  | /** Norwegian Krone */ NOK
  | /** Swedish Krona */ SEK
  | /** US Dollar */ USD

  // ── Dormant ─────────────────────────────────────────────────────────────
  // The rest of ISO 4217, kept for the day one of them is needed. Uncomment
  // the code here and in the other three blocks — or add it to `active` in
  // scripts/GenerateCurrency.res and regenerate — to admit it.
  // | /** UAE Dirham */ AED
  // | /** Afghani */ AFN
  // | /** Lek */ ALL
  // | /** Armenian Dram */ AMD
  // | /** Kwanza */ AOA
  // | /** Argentine Peso */ ARS
  // | /** Aruban Florin */ AWG
  // | /** Azerbaijan Manat */ AZN
  // | /** Convertible Mark */ BAM
  // | /** Barbados Dollar */ BBD
  // | /** Taka */ BDT
  // | /** Bahraini Dinar */ BHD
  // | /** Burundi Franc */ BIF
  // | /** Bermudian Dollar */ BMD
  // | /** Brunei Dollar */ BND
  // | /** Boliviano */ BOB
  // | /** BOV */ BOV
  // | /** Brazilian Real */ BRL
  // | /** Bahamian Dollar */ BSD
  // | /** Ngultrum */ BTN
  // | /** Pula */ BWP
  // | /** Belarusian Ruble */ BYN
  // | /** Belize Dollar */ BZD
  // | /** Congolese Franc */ CDF
  // | /** CHE */ CHE
  // | /** CHW */ CHW
  // | /** CLF */ CLF
  // | /** Chilean Peso */ CLP
  // | /** Colombian Peso */ COP
  // | /** COU */ COU
  // | /** Costa Rican Colon */ CRC
  // | /** Cuban Peso */ CUP
  // | /** Cabo Verde Escudo */ CVE
  // | /** Czech Koruna */ CZK
  // | /** Djibouti Franc */ DJF
  // | /** Danish Krone */ DKK
  // | /** Dominican Peso */ DOP
  // | /** Algerian Dinar */ DZD
  // | /** Egyptian Pound */ EGP
  // | /** Nakfa */ ERN
  // | /** Ethiopian Birr */ ETB
  // | /** Fiji Dollar */ FJD
  // | /** Falkland Islands Pound */ FKP
  // | /** Lari */ GEL
  // | /** Ghana Cedi */ GHS
  // | /** Gibraltar Pound */ GIP
  // | /** Dalasi */ GMD
  // | /** Guinean Franc */ GNF
  // | /** Quetzal */ GTQ
  // | /** Guyana Dollar */ GYD
  // | /** Hong Kong Dollar */ HKD
  // | /** Lempira */ HNL
  // | /** Gourde */ HTG
  // | /** Forint */ HUF
  // | /** Rupiah */ IDR
  // | /** New Israeli Sheqel */ ILS
  // | /** Indian Rupee */ INR
  // | /** Iraqi Dinar */ IQD
  // | /** Iranian Rial */ IRR
  // | /** Iceland Krona */ ISK
  // | /** Jamaican Dollar */ JMD
  // | /** Jordanian Dinar */ JOD
  // | /** Kenyan Shilling */ KES
  // | /** Som */ KGS
  // | /** Riel */ KHR
  // | /** Comorian Franc */ KMF
  // | /** North Korean Won */ KPW
  // | /** Won */ KRW
  // | /** Kuwaiti Dinar */ KWD
  // | /** Cayman Islands Dollar */ KYD
  // | /** Tenge */ KZT
  // | /** Lao Kip */ LAK
  // | /** Lebanese Pound */ LBP
  // | /** Sri Lanka Rupee */ LKR
  // | /** Liberian Dollar */ LRD
  // | /** Loti */ LSL
  // | /** Libyan Dinar */ LYD
  // | /** Moroccan Dirham */ MAD
  // | /** Moldovan Leu */ MDL
  // | /** Malagasy Ariary */ MGA
  // | /** Denar */ MKD
  // | /** Kyat */ MMK
  // | /** Tugrik */ MNT
  // | /** Pataca */ MOP
  // | /** Ouguiya */ MRU
  // | /** Mauritius Rupee */ MUR
  // | /** Rufiyaa */ MVR
  // | /** Malawi Kwacha */ MWK
  // | /** Mexican Peso */ MXN
  // | /** MXV */ MXV
  // | /** Malaysian Ringgit */ MYR
  // | /** Mozambique Metical */ MZN
  // | /** Namibia Dollar */ NAD
  // | /** Naira */ NGN
  // | /** Cordoba Oro */ NIO
  // | /** Nepalese Rupee */ NPR
  // | /** New Zealand Dollar */ NZD
  // | /** Rial Omani */ OMR
  // | /** Balboa */ PAB
  // | /** Sol */ PEN
  // | /** Kina */ PGK
  // | /** Philippine Peso */ PHP
  // | /** Pakistan Rupee */ PKR
  // | /** Zloty */ PLN
  // | /** Guarani */ PYG
  // | /** Qatari Rial */ QAR
  // | /** Romanian Leu */ RON
  // | /** Serbian Dinar */ RSD
  // | /** Russian Ruble */ RUB
  // | /** Rwanda Franc */ RWF
  // | /** Saudi Riyal */ SAR
  // | /** Solomon Islands Dollar */ SBD
  // | /** Seychelles Rupee */ SCR
  // | /** Sudanese Pound */ SDG
  // | /** Singapore Dollar */ SGD
  // | /** Saint Helena Pound */ SHP
  // | /** Leone */ SLE
  // | /** Somali Shilling */ SOS
  // | /** Surinam Dollar */ SRD
  // | /** South Sudanese Pound */ SSP
  // | /** Dobra */ STN
  // | /** El Salvador Colon */ SVC
  // | /** Syrian Pound */ SYP
  // | /** Lilangeni */ SZL
  // | /** Baht */ THB
  // | /** Somoni */ TJS
  // | /** Turkmenistan New Manat */ TMT
  // | /** Tunisian Dinar */ TND
  // | /** Pa’anga */ TOP
  // | /** Turkish Lira */ TRY
  // | /** Trinidad and Tobago Dollar */ TTD
  // | /** New Taiwan Dollar */ TWD
  // | /** Tanzanian Shilling */ TZS
  // | /** Hryvnia */ UAH
  // | /** Uganda Shilling */ UGX
  // | /** USN */ USN
  // | /** UYI */ UYI
  // | /** Peso Uruguayo */ UYU
  // | /** Unidad Previsional */ UYW
  // | /** Uzbekistan Sum */ UZS
  // | /** Bolívar Soberano */ VED
  // | /** Bolívar Soberano */ VES
  // | /** Dong */ VND
  // | /** Vatu */ VUV
  // | /** Tala */ WST
  // | /** Arab Accounting Dinar */ XAD
  // | /** CFA Franc BEAC */ XAF
  // | /** East Caribbean Dollar */ XCD
  // | /** Caribbean Guilder */ XCG
  // | /** CFA Franc BCEAO */ XOF
  // | /** CFP Franc */ XPF
  // | /** Yemeni Rial */ YER
  // | /** Rand */ ZAR
  // | /** Zambian Kwacha */ ZMW
  // | /** Zimbabwe Gold */ ZWG

/** Every currency the type admits, in code order. `fromString` is derived from
    this, so a code that parses and a code that exists are the same set by
    construction. */
let all: array<t> = [
  AUD, CAD, CHF, CNY, EUR, GBP, JPY, NOK, SEK, USD,
  // AED, AFN, ALL, AMD, AOA, ARS, AWG, AZN, BAM, BBD, BDT, BHD, BIF, BMD, BND, BOB, BOV, BRL,
  // BSD, BTN, BWP, BYN, BZD, CDF, CHE, CHW, CLF, CLP, COP, COU, CRC, CUP, CVE, CZK, DJF, DKK,
  // DOP, DZD, EGP, ERN, ETB, FJD, FKP, GEL, GHS, GIP, GMD, GNF, GTQ, GYD, HKD, HNL, HTG, HUF,
  // IDR, ILS, INR, IQD, IRR, ISK, JMD, JOD, KES, KGS, KHR, KMF, KPW, KRW, KWD, KYD, KZT, LAK,
  // LBP, LKR, LRD, LSL, LYD, MAD, MDL, MGA, MKD, MMK, MNT, MOP, MRU, MUR, MVR, MWK, MXN, MXV,
  // MYR, MZN, NAD, NGN, NIO, NPR, NZD, OMR, PAB, PEN, PGK, PHP, PKR, PLN, PYG, QAR, RON, RSD,
  // RUB, RWF, SAR, SBD, SCR, SDG, SGD, SHP, SLE, SOS, SRD, SSP, STN, SVC, SYP, SZL, THB, TJS,
  // TMT, TND, TOP, TRY, TTD, TWD, TZS, UAH, UGX, USN, UYI, UYU, UYW, UZS, VED, VES, VND, VUV,
  // WST, XAD, XAF, XCD, XCG, XOF, XPF, YER, ZAR, ZMW, ZWG,
]

/** The currency's ISO 4217 alphabetic code. */
let toString = (currency: t): string =>
  switch currency {
  | AUD => "AUD"
  | CAD => "CAD"
  | CHF => "CHF"
  | CNY => "CNY"
  | EUR => "EUR"
  | GBP => "GBP"
  | JPY => "JPY"
  | NOK => "NOK"
  | SEK => "SEK"
  | USD => "USD"
  // | AED => "AED"
  // | AFN => "AFN"
  // | ALL => "ALL"
  // | AMD => "AMD"
  // | AOA => "AOA"
  // | ARS => "ARS"
  // | AWG => "AWG"
  // | AZN => "AZN"
  // | BAM => "BAM"
  // | BBD => "BBD"
  // | BDT => "BDT"
  // | BHD => "BHD"
  // | BIF => "BIF"
  // | BMD => "BMD"
  // | BND => "BND"
  // | BOB => "BOB"
  // | BOV => "BOV"
  // | BRL => "BRL"
  // | BSD => "BSD"
  // | BTN => "BTN"
  // | BWP => "BWP"
  // | BYN => "BYN"
  // | BZD => "BZD"
  // | CDF => "CDF"
  // | CHE => "CHE"
  // | CHW => "CHW"
  // | CLF => "CLF"
  // | CLP => "CLP"
  // | COP => "COP"
  // | COU => "COU"
  // | CRC => "CRC"
  // | CUP => "CUP"
  // | CVE => "CVE"
  // | CZK => "CZK"
  // | DJF => "DJF"
  // | DKK => "DKK"
  // | DOP => "DOP"
  // | DZD => "DZD"
  // | EGP => "EGP"
  // | ERN => "ERN"
  // | ETB => "ETB"
  // | FJD => "FJD"
  // | FKP => "FKP"
  // | GEL => "GEL"
  // | GHS => "GHS"
  // | GIP => "GIP"
  // | GMD => "GMD"
  // | GNF => "GNF"
  // | GTQ => "GTQ"
  // | GYD => "GYD"
  // | HKD => "HKD"
  // | HNL => "HNL"
  // | HTG => "HTG"
  // | HUF => "HUF"
  // | IDR => "IDR"
  // | ILS => "ILS"
  // | INR => "INR"
  // | IQD => "IQD"
  // | IRR => "IRR"
  // | ISK => "ISK"
  // | JMD => "JMD"
  // | JOD => "JOD"
  // | KES => "KES"
  // | KGS => "KGS"
  // | KHR => "KHR"
  // | KMF => "KMF"
  // | KPW => "KPW"
  // | KRW => "KRW"
  // | KWD => "KWD"
  // | KYD => "KYD"
  // | KZT => "KZT"
  // | LAK => "LAK"
  // | LBP => "LBP"
  // | LKR => "LKR"
  // | LRD => "LRD"
  // | LSL => "LSL"
  // | LYD => "LYD"
  // | MAD => "MAD"
  // | MDL => "MDL"
  // | MGA => "MGA"
  // | MKD => "MKD"
  // | MMK => "MMK"
  // | MNT => "MNT"
  // | MOP => "MOP"
  // | MRU => "MRU"
  // | MUR => "MUR"
  // | MVR => "MVR"
  // | MWK => "MWK"
  // | MXN => "MXN"
  // | MXV => "MXV"
  // | MYR => "MYR"
  // | MZN => "MZN"
  // | NAD => "NAD"
  // | NGN => "NGN"
  // | NIO => "NIO"
  // | NPR => "NPR"
  // | NZD => "NZD"
  // | OMR => "OMR"
  // | PAB => "PAB"
  // | PEN => "PEN"
  // | PGK => "PGK"
  // | PHP => "PHP"
  // | PKR => "PKR"
  // | PLN => "PLN"
  // | PYG => "PYG"
  // | QAR => "QAR"
  // | RON => "RON"
  // | RSD => "RSD"
  // | RUB => "RUB"
  // | RWF => "RWF"
  // | SAR => "SAR"
  // | SBD => "SBD"
  // | SCR => "SCR"
  // | SDG => "SDG"
  // | SGD => "SGD"
  // | SHP => "SHP"
  // | SLE => "SLE"
  // | SOS => "SOS"
  // | SRD => "SRD"
  // | SSP => "SSP"
  // | STN => "STN"
  // | SVC => "SVC"
  // | SYP => "SYP"
  // | SZL => "SZL"
  // | THB => "THB"
  // | TJS => "TJS"
  // | TMT => "TMT"
  // | TND => "TND"
  // | TOP => "TOP"
  // | TRY => "TRY"
  // | TTD => "TTD"
  // | TWD => "TWD"
  // | TZS => "TZS"
  // | UAH => "UAH"
  // | UGX => "UGX"
  // | USN => "USN"
  // | UYI => "UYI"
  // | UYU => "UYU"
  // | UYW => "UYW"
  // | UZS => "UZS"
  // | VED => "VED"
  // | VES => "VES"
  // | VND => "VND"
  // | VUV => "VUV"
  // | WST => "WST"
  // | XAD => "XAD"
  // | XAF => "XAF"
  // | XCD => "XCD"
  // | XCG => "XCG"
  // | XOF => "XOF"
  // | XPF => "XPF"
  // | YER => "YER"
  // | ZAR => "ZAR"
  // | ZMW => "ZMW"
  // | ZWG => "ZWG"
  }

/**
How many decimal places the currency's minor unit is: 2 for EUR, **0 for JPY**.
Among the dormant codes it reaches 3 (TND) and 4 (the Chilean Unidad de
Fomento), which is why nothing here may assume two.

Total by construction — this is the whole reason the type is closed and the
table is generated. An amount carries exactly this many decimals, so this is the
only thing that says how precise one may be.
*/
let exponent = (currency: t): int =>
  switch currency {
  | AUD => 2
  | CAD => 2
  | CHF => 2
  | CNY => 2
  | EUR => 2
  | GBP => 2
  | JPY => 0
  | NOK => 2
  | SEK => 2
  | USD => 2
  // | AED => 2
  // | AFN => 2
  // | ALL => 2
  // | AMD => 2
  // | AOA => 2
  // | ARS => 2
  // | AWG => 2
  // | AZN => 2
  // | BAM => 2
  // | BBD => 2
  // | BDT => 2
  // | BHD => 3
  // | BIF => 0
  // | BMD => 2
  // | BND => 2
  // | BOB => 2
  // | BOV => 2
  // | BRL => 2
  // | BSD => 2
  // | BTN => 2
  // | BWP => 2
  // | BYN => 2
  // | BZD => 2
  // | CDF => 2
  // | CHE => 2
  // | CHW => 2
  // | CLF => 4
  // | CLP => 0
  // | COP => 2
  // | COU => 2
  // | CRC => 2
  // | CUP => 2
  // | CVE => 2
  // | CZK => 2
  // | DJF => 0
  // | DKK => 2
  // | DOP => 2
  // | DZD => 2
  // | EGP => 2
  // | ERN => 2
  // | ETB => 2
  // | FJD => 2
  // | FKP => 2
  // | GEL => 2
  // | GHS => 2
  // | GIP => 2
  // | GMD => 2
  // | GNF => 0
  // | GTQ => 2
  // | GYD => 2
  // | HKD => 2
  // | HNL => 2
  // | HTG => 2
  // | HUF => 2
  // | IDR => 2
  // | ILS => 2
  // | INR => 2
  // | IQD => 3
  // | IRR => 2
  // | ISK => 0
  // | JMD => 2
  // | JOD => 3
  // | KES => 2
  // | KGS => 2
  // | KHR => 2
  // | KMF => 0
  // | KPW => 2
  // | KRW => 0
  // | KWD => 3
  // | KYD => 2
  // | KZT => 2
  // | LAK => 2
  // | LBP => 2
  // | LKR => 2
  // | LRD => 2
  // | LSL => 2
  // | LYD => 3
  // | MAD => 2
  // | MDL => 2
  // | MGA => 2
  // | MKD => 2
  // | MMK => 2
  // | MNT => 2
  // | MOP => 2
  // | MRU => 2
  // | MUR => 2
  // | MVR => 2
  // | MWK => 2
  // | MXN => 2
  // | MXV => 2
  // | MYR => 2
  // | MZN => 2
  // | NAD => 2
  // | NGN => 2
  // | NIO => 2
  // | NPR => 2
  // | NZD => 2
  // | OMR => 3
  // | PAB => 2
  // | PEN => 2
  // | PGK => 2
  // | PHP => 2
  // | PKR => 2
  // | PLN => 2
  // | PYG => 0
  // | QAR => 2
  // | RON => 2
  // | RSD => 2
  // | RUB => 2
  // | RWF => 0
  // | SAR => 2
  // | SBD => 2
  // | SCR => 2
  // | SDG => 2
  // | SGD => 2
  // | SHP => 2
  // | SLE => 2
  // | SOS => 2
  // | SRD => 2
  // | SSP => 2
  // | STN => 2
  // | SVC => 2
  // | SYP => 2
  // | SZL => 2
  // | THB => 2
  // | TJS => 2
  // | TMT => 2
  // | TND => 3
  // | TOP => 2
  // | TRY => 2
  // | TTD => 2
  // | TWD => 2
  // | TZS => 2
  // | UAH => 2
  // | UGX => 0
  // | USN => 2
  // | UYI => 0
  // | UYU => 2
  // | UYW => 4
  // | UZS => 2
  // | VED => 2
  // | VES => 2
  // | VND => 0
  // | VUV => 0
  // | WST => 2
  // | XAD => 2
  // | XAF => 0
  // | XCD => 2
  // | XCG => 2
  // | XOF => 0
  // | XPF => 0
  // | YER => 2
  // | ZAR => 2
  // | ZMW => 2
  // | ZWG => 2
  }

let byCode: dict<t> = {
  let d = Dict.make()
  all->Array.forEach(c => d->Dict.set(toString(c), c))
  d
}

/**
Parse an ISO 4217 alphabetic code, saying why when it is not one.

Case-sensitive on purpose: `"eur"` is rejected rather than repaired. This type
exists because a silent case mismatch is expensive to find, and quietly
accepting the wrong spelling at the boundary would put it back — a producer
sending lowercase codes should learn that at its first request, not at the first
report that two halves of a ledger disagree.

A code the standard defines but this type does not admit is rejected the same
way, and the message says so: the caller's next move is to admit it, not to
correct the spelling.
*/
let fromString = (raw: string): result<t, string> =>
  switch byCode->Dict.get(raw) {
  | Some(c) => Ok(c)
  | None =>
    Error(
      `expected one of the ISO 4217 codes this framework admits (${all
        ->Array.map(toString)
        ->Array.join(", ")}), got ${raw
        ->JSON.Encode.string
        ->JSON.stringify}. Codes are upper-case and exactly three letters.`,
    )
  }
