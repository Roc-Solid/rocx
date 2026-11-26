import pf.Server
import pf.Endpoint
import ../../../../Middlewares

## GET /api/ebook: for those who bought it only (`Middlewares.readers`): its chapters.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ title : Str, chapters : List(Str) }, Endpoint.Refusal)
get! = |_| Ok({ title: "A small book about Roc", chapters: ["Values", "Functions", "Records and tags", "Effects"] })
