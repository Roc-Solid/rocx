import pf.Server
import pf.Endpoint
import forms.Date
import forms.Issues
import ../../PlateForm
import ../../Store

## POST /weights, from the trends page's form: a weight for a day, in place of one it had; the
## profile's weight too when it's the latest, so the targets follow.
post! : { request : Server.Request, params : {}, context : {}, body : { day : Str, kg : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }|
	match PlateForm.weight.parse_body(Server.text_of(request)) {
		Ok(weight) => Store.weigh!(Date.to_str(weight.day), weight.kg).map_err!(Store.refusal!)
		Err(issues) => Err(Issues.refusal(issues))
	}
