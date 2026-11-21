import pf.Server
import pf.Endpoint
import otel.Metric
import ../../../Otel

## Greetings given, by whether the name was a long one.
greetings : Metric.Instrument
greetings = Metric.counter({ name: "app.greetings", description: "Greetings given.", unit: "{greeting}" })

## GET /hello/<name>: a greeting, counted.
get! : { request : Server.Request, params : { name : Str }, context : c } => Try(Str, Endpoint.Refusal)
get! = |input| {
	name = input.params.name
	Otel.record!(greetings, 1, [("long", if (name.count_utf8_bytes() > 8) "yes" else "no")])
	Ok("Hello, ${name}!")
}
