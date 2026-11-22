import pf.Server
import pf.Endpoint

## GET /api/shout/:word: the word, shouted, and how many bytes it has.
get! : { request : Server.Request, params : { word : Str }, context : c } => Try({ word : Str, shouted : Str, bytes : U64 }, Endpoint.Refusal)
get! = |{ params, .. }|
	Ok({ word: params.word, shouted: params.word.with_ascii_uppercased(), bytes: params.word.to_utf8().len() })
