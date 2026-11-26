import pf.Server
import pf.Endpoint
import forms.Date
import ../../PlateForm
import ../../Store

## What POST /weights is sent: a day and a weight, read and checked by `PlateForm.weight` (D-093).
post_body = PlateForm.weight

## POST /weights, from the trends page's form: a weight for a day, in place of one it had; the
## profile's weight too when it's the latest, so the targets follow.
post! : { request : Server.Request, params : {}, context : {}, body : PlateForm.Weight } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| Store.weigh!(Date.to_str(body.day), body.kg).map_err!(Store.refusal!)
