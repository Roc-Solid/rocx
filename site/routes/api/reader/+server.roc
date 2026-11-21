## GET /api/reader: who is reading, as a session would say on the server (here, always Ada). The
## bag demo reads it as the page renders, and the page carries the answer.

get! = |_| Ok("Ada")
