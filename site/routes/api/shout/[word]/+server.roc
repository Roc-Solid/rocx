## GET /api/shout/:word: the word, shouted, and how many bytes it has.

get! = |{ params, .. }|
	Ok({ word: params.word, shouted: params.word.with_ascii_uppercased(), bytes: params.word.to_utf8().len() })
