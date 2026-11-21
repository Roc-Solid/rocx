import pf.Server
import pf.Endpoint
import intl.Locale

## POST /locale, `tag=pl` (a form) or `{"tag":"pl"}` (the picker): keeps the reader's choice in the
## `locale` cookie for a year. A form's post goes back to the page it came from.
post! : { request : Server.Request, params : {}, context : c, body : { tag : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, body, .. }|
	match Locale.parse(body.tag) {
		Ok(locale) => {
			kept = |answer| Server.set_cookie(answer, "locale", locale.tag(), { ..Server.cookie_defaults, max_age_s: 365 * 86400 })
			if Server.wants_html(request) {
				Err(Answer(kept(Server.redirect(Server.header(request, "referer") ?? "/"))))
			} else {
				Err(Answer(kept(Server.response(204, [], ""))))
			}
		}
		Err(_) => Err(BadRequest("not a language tag: ${body.tag}"))
	}
