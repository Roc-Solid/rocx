## Testing: find things in a page as a person finds them, by role and name, by text, by label, by
## test id. `Dom.parse` reads HTML (`Html.to_str` of a component, a page a test fetched) into a
## tree, and its queries are Testing Library's, so a test reads as what someone sees, not as the
## page's classes. It is plain Roc, on no platform, so any `expect` can use it. See README.md.
package [Dom] {}
