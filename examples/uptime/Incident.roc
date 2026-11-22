import Days

## When incidents open and close, and what is said about them: plain Roc, so its `expect`s are the
## rules. A check calls `decide` with what it found (Checks.roc), in the transaction that stores it.
##
## - An incident **opens** on the check that makes a monitor's streak of failures in a row reach its
##   `threshold` (3 unless the admin says otherwise), if it has none open.
## - It **closes** on the next check that passes.
## - Closed by hand while the monitor still fails, it stays closed: the streak is past the threshold
##   by then, and a new one opens only after the monitor passes a check and fails again.
Incident := [].{

	## What a check does to its monitor's incident.
	Decision : [Open, Close, Keep]

	## What the check found (`up`), the streak of failures after it (0 when it passed), the
	## monitor's threshold, and whether an incident is open.
	decide : { up : Bool, streak : U64, threshold : U64, open : Bool } -> Incident.Decision
	decide = |{ up, streak, threshold, open }|
		if up {
			if (open) Close else Keep
		} else if !open and streak == threshold {
			Open
		} else {
			Keep
		}

	## Where an incident stands, as its updates say: the words statuspages use.
	Stage : [Investigating, Identified, Monitoring, Resolved]

	## Every stage, in order, for the admin's form.
	stages : List(Incident.Stage)
	stages = [Investigating, Identified, Monitoring, Resolved]

	## A stage as the database keeps it (`incident_updates.state`).
	stage_name : Incident.Stage -> Str
	stage_name = |stage|
		match stage {
			Investigating => "investigating"
			Identified => "identified"
			Monitoring => "monitoring"
			Resolved => "resolved"
		}

	## A stage as a page says it.
	stage_label : Incident.Stage -> Str
	stage_label = |stage|
		match stage {
			Investigating => "Investigating"
			Identified => "Identified"
			Monitoring => "Monitoring"
			Resolved => "Resolved"
		}

	## The stage the database keeps as `name`.
	stage_of : Str -> Try(Incident.Stage, [Unknown])
	stage_of = |name|
		match name {
			"investigating" => Ok(Investigating)
			"identified" => Ok(Identified)
			"monitoring" => Ok(Monitoring)
			"resolved" => Ok(Resolved)
			_ => Err(Unknown)
		}

	## A stage's label, from the name the database keeps.
	label_of : Str -> Str
	label_of = |name|
		match Incident.stage_of(name) {
			Ok(stage) => Incident.stage_label(stage)
			Err(Unknown) => name
		}

	## The title of an incident the checks open.
	title : Str -> Str
	title = |monitor| "${monitor} is down"

	## What a check said about it: the first update of an incident it opened, and the last of one it
	## closed (`minutes` it was down, and how the passing check answered).
	opened : { name : Str, failures : U64, problem : Str } -> Str
	opened = |{ name, failures, problem }| "${name} failed ${failures.to_str()} checks in a row (${problem})."

	## The last update of an incident a passing check closed.
	closed : { name : Str, minutes : U64, status : U64, latency_ms : U64 } -> Str
	closed = |{ name, minutes, status, latency_ms }| "${name} answers again (${status.to_str()} in ${latency_ms.to_str()} ms) after ${Days.minutes(U64.max(minutes, 1))}."
}

expect Incident.decide({ up: Bool.False, streak: 1, threshold: 3, open: Bool.False }) == Keep
expect Incident.decide({ up: Bool.False, streak: 2, threshold: 3, open: Bool.False }) == Keep
expect Incident.decide({ up: Bool.False, streak: 3, threshold: 3, open: Bool.False }) == Open
expect Incident.decide({ up: Bool.False, streak: 1, threshold: 1, open: Bool.False }) == Open
# Already open: more failures change nothing.
expect Incident.decide({ up: Bool.False, streak: 4, threshold: 3, open: Bool.True }) == Keep
# Closed by hand while still failing: no new one until it has passed and failed again.
expect Incident.decide({ up: Bool.False, streak: 5, threshold: 3, open: Bool.False }) == Keep
# A pass closes an open one, and is nothing otherwise.
expect Incident.decide({ up: Bool.True, streak: 0, threshold: 3, open: Bool.True }) == Close
expect Incident.decide({ up: Bool.True, streak: 0, threshold: 3, open: Bool.False }) == Keep

# Up, then three failures, then a pass: one incident opened and closed.
expect {
	threshold = 3
	steps = [Bool.True, Bool.False, Bool.False, Bool.False, Bool.False, Bool.True]
	final = steps.fold(
		{ streak: 0, open: Bool.False, said: [] },
		|now, up| {
			streak = if (up) 0 else now.streak + 1
			decision = Incident.decide({ up, streak, threshold, open: now.open })
			open =
				match decision {
					Open => Bool.True
					Close => Bool.False
					Keep => now.open
				}
			{ streak, open, said: now.said.append(decision) }
		},
	)
	final.said == [Keep, Keep, Keep, Open, Keep, Close]
}

expect Incident.stage_of("monitoring") == Ok(Monitoring)
expect Incident.stage_of("done") == Err(Unknown)
expect Incident.stages.map(Incident.stage_name) == ["investigating", "identified", "monitoring", "resolved"]
expect Incident.opened({ name: "Payments API", failures: 3, problem: "expected 200, got 503" }) == "Payments API failed 3 checks in a row (expected 200, got 503)."
expect Incident.closed({ name: "Payments API", minutes: 23, status: 200, latency_ms: 96 }) == "Payments API answers again (200 in 96 ms) after 23 minutes."
expect Incident.closed({ name: "Payments API", minutes: 0, status: 200, latency_ms: 96 }) == "Payments API answers again (200 in 96 ms) after 1 minute."
