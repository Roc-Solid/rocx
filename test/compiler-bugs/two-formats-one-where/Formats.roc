## A where clause asking a type to be readable by two formats, whose aliases
## each require a `read` method of their own format. No type has two `read`
## methods, so checking rejects `both`'s annotation and retires `both`.
Formats := [].{
	Left := [L].{
		a.Readable : where [a.read : Left -> a]
	}

	Right := [R].{
		a.Readable : where [a.read : Right -> a]
	}

	both : {} -> a where [a.Left.Readable, a.Right.Readable]
	both = |{}| crash "never called"
}
