## Internationalisation: locales and how to pick one (`Locale`), each locale's data from CLDR
## (`Locales`), plural rules (`Plural`), numbers, money and compact numbers (`NumberFormat`), days
## (`Date`) and how dates and times are written (`DateFormat`), relative times (`RelativeTime`),
## ICU messages (`Message`) in catalogs of translations (`Catalog`), the words for packages/forms'
## issues (`Validation`), and `Intl`, which puts them together for one locale. It is plain Roc, on
## no platform, so a page the server renders and a component in the browser write the same text.
##
## The `Language` context and picker are in `components/`: `rocx generate` copies them into each app
## that names this package. See README.md.
package [Catalog, Date, DateFormat, Intl, Locale, Locales, Message, NumberFormat, Plural, RelativeTime, Validation] {}
