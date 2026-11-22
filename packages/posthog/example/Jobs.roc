import jobs.Job

## The app's jobs.
Jobs := [].{

	## A charge the card provider always declines.
	charge : Job.Kind({ order : U64 })
	charge = Job.define("charge", |{ order }| Err("the card for order ${order.to_str()} was declined"))
}
