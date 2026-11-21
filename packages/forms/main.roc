## Forms: a form's rules written once, in Roc, and run on both sides. A browser checks what is
## typed as it is typed, and the endpoint the form posts to reads what was posted with the very same
## rules, into a typed record, or refuses it with the same issues, field by field. The rules go past
## what a type says: lengths, patterns (`Regex`, linear-time, in plain Roc), email addresses, ranges
## and steps, choices, days, lists, and checks across fields.
##
## `Value` reads one value and checks it; `Form` puts values under the names a form posts them as,
## with Roc's record builder (`{ name: Form.text("name", [Required]), … }.Form`); `Issues` are what
## is wrong, each a code and its English; `Date` is a day; `Regex` matches patterns. It is plain Roc,
## on no platform, so the browser's half of an app and the server's use the same code.
##
## The components (`<TextField>`, `<CheckboxField>`, `<IssueSummary>`, and `LiveForm`, a form's
## state in a component) are in `components/`: `rocx build` copies them into each app that names
## this package. See README.md.
package [Date, Form, Issues, Regex, Value] {}
