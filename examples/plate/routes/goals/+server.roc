import pf.Server
import pf.Endpoint
import forms.Date
import forms.Issues
import ../../Plate
import ../../PlateForm
import ../../Session
import ../../Store

## GET /goals, for JSON: the profile the targets are worked out from, this year (for its age),
## and whether the diary has a password.
get! : { request : Server.Request, params : {}, context : {} } => Try(Plate.Goals, Endpoint.Refusal)
get! = |_| {
	profile = Store.profile!({}).map_err!(Store.refusal!)?
	today = Store.today!({}).map_err!(Store.refusal!)?
	year = Date.from_str(today).map_ok(|date| date.year()) ?? 2026
	Ok({ profile, year, locked: !Session.open!({}) })
}

## What POST /goals is sent: the profile, read and checked by `PlateForm.profile` (D-093).
post_body = PlateForm.profile

## POST /goals, from the profile's form: the profile changed, and with it every day's targets
## (a past day's too: they're worked out as a day is read). A time zone Postgres doesn't know is
## refused under its field.
post! : { request : Server.Request, params : {}, context : {}, body : Plate.Profile } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Store.save_profile!(body) {
		Ok({}) => Ok({})
		Err(BadZone) => Err(Issues.refusal([{ field: "timezone", code: Custom("zone", "Not a time zone this server knows"), message: "Not a time zone this server knows: try one like Europe/Berlin" }]))
		Err(NotFound) => Err(NotFound)
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Store.refusal!(DbErr(why)))
	}
