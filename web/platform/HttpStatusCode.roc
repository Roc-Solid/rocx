import Host
import Html

## `<HttpStatusCode code={404} />`, as SolidStart has it: the status the server answers the page
## with, rendered nowhere. In the browser it does nothing: the page has its status already.
HttpStatusCode := [].{
	view! : { code : U16 } => Html
	view! = |{ code }| {
		Host.status!(code)
		Html.empty({})
	}
}
