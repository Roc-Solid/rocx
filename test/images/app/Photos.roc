import "photos/one.png" as one_png : List(U8)

## The photo a route answers, kept in the app (not in static/, which the server would serve itself).
Photos := [].{
	one : List(U8)
	one = one_png
}
