import pf.Db
import pf.Server
import pf.Endpoint

## GET /health: whether this app answers and its database does, the seeded "Status page" monitor's
## URL. 503 when the database doesn't answer.
get! : { request : Server.Request, params : {}, context : {} } => Try({ ok : Bool, database : Str }, Endpoint.Refusal)
get! = |_| {
	answered : Try(List({ one : I64 }), [DbErr(Str), BadRow(Str)])
	answered = Db.all!("select 1 as one", [])
	match answered {
		Ok(_) => Ok({ ok: Bool.True, database: "up" })
		Err(_) => Err(Status(503, "The database doesn't answer."))
	}
}
