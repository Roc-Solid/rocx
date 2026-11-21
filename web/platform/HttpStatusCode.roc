import Host
import Html

## `<HttpStatusCode code={404} />`, as SolidStart has it: the status the server answers the page
## with, rendered nowhere. In the browser it does nothing: the page has its status already.
HttpStatusCode := [].{

	## What `<HttpStatusCode code={…} />` is: on the server, sets the status the page is answered
	## with; in the browser, nothing. It renders nothing.
	view! : { code : U16 } => Html
	view! = |{ code }| {
		Host.status!(code)
		Html.empty({})
	}
}
