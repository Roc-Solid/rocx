import pf.Server
import pf.Endpoint
import ../../../Store

## POST /api/subscribe, from the status page's form: `email`, mailed when an incident opens or closes.
## An address already subscribed is told the same, so the form says nothing about who else is.
post! : { request : Server.Request, params : {}, context : {}, body : { email : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| {
	email = body.email.trim()
	if !valid(email) {
		Err(BadRequest("That doesn't look like an email address."))
	} else {
		match Store.subscribe!(email) {
			Ok(_) => Ok("Subscribed: ${email} hears about incidents as they open and close.")
			Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
		}
	}
}

## An address worth trying: something, an `@`, and a domain with a dot, without spaces. The mail
## server says the rest.
valid : Str -> Bool
valid = |email| {
	parts = email.split_on("@")
	domain = parts.get(1) ?? ""
	parts.len() == 2 and !(parts.first() ?? "").is_empty() and domain.contains(".") and !domain.starts_with(".") and !domain.ends_with(".") and !email.contains(" ") and email.to_utf8().len() <= 254
}

expect valid("ada@example.com")
expect !valid("ada")
expect !valid("ada@example")
expect !valid("a b@example.com")
expect !valid("@example.com")
expect !valid("ada@@example.com")
