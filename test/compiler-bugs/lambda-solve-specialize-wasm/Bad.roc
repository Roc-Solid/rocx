## `roc test --opt=size --specialize=yes Bad.roc` crashes in `post-check lambda_solve`: `keep` is
## given a known function and wraps it in a closure, and closures in two top-level functions
## (`main`'s and `view`'s) call it. Without specialization the expect passes.
Bad := [].{
	keep = |pred| [].keep_if(|item| Bad.apply(pred, item))

	apply = |f, x| f(x)

	id = |x| x

	main = |{}| {
		pred = Str.is_empty
		first = Bad.id(|| Bad.keep(pred))
		Bad.view({ first, pred })
	}

	view = |{ first: _, pred }| Bad.ignore(|| Bad.keep(pred))

	ignore = |_| ""
}

expect Bad.main({}) == ""
