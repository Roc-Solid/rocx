import Host
import Html

## `<A>`, Solid Router's: a link (`<a href>`), which navigates in place as any same-app `<a>` does
## (D-040), with an active state. While the location is at its path (with `end`) or under it
## (without), it has `aria-current="page"` and the class `active_class` (`active` unless it says
## another), and follows each navigation: it reads `Router.location!` where it is used.
##
##     import pf.A
##
##     <A href={Paths.lists_id({ id: list!().id })} active_class="current">{list!().name}</A>
##     <A href={Paths.root} end>Home</A>      # active only at / itself, not under it
##
## Under, part by part: `/lists` is active at `/lists/7`, not at `/listsx`; `/` is active everywhere,
## unless `end`. A query or a hash in `href` doesn't count, and a query alone (`?card=12`) is the
## page's own path. Its other props are written on the `<a>` for the runtime: `replace` (the entry
## replaced, not pushed), `noscroll` (the scroll left where it is) and `preload` (`Bool.False`: not
## prefetched, `data-rocx-preload="off"`). Written in a component with a `<style>`, it is styled as
## an `<a>` there is: rocx gives it the component's class, beside its own `class`. It is marked
## `data-rocx-link`, so it navigates in place under `<html data-rocx-navigation="explicit">` too,
## where a plain `<a>` doesn't.
A := [].{
	Props := { href : Str, end : Bool ?? Bool.False, active_class : Str ?? "active", class : Str ?? "", replace : Bool ?? Bool.False, noscroll : Bool ?? Bool.False, preload : Bool ?? Bool.True, children : List(Html) }

	## What `<A href={…}>…</A>` is: an `<a>`, active while the location is at its path or under it.
	view! : Props => Html
	view! = |props| {
		href = props.href
		end = props.end
		active! = || A.active(Host.location!({}), href, end)
		attrs =
			[Html.attr("href", href), Html.attr("data-rocx-link", "")]
				.concat(if (props.class.is_empty()) [] else [Html.attr("class", props.class)])
				.concat([Html.class_of(props.active_class, active!), Html.optional_of("aria-current", || if (active!()) "page" else "")])
				.concat(if (props.replace) [Html.flag("replace", Bool.True)] else [])
				.concat(if (props.noscroll) [Html.flag("noscroll", Bool.True)] else [])
				.concat(if (props.preload) [] else [Html.attr("data-rocx-preload", "off")])
		Html.element("a", attrs, props.children)
	}

	## Whether a link to `href` is active at `location` (`/lists/7?days=30`, as `Router.location!`
	## says it): its path the same (`end`), or the same or above it, part by part. A query alone is
	## the location's own path.
	active : Str, Str, Bool -> Bool
	active = |location, href, end| {
		here = A.path_of(location)
		target = if (href.starts_with("?") or href.starts_with("#") or href.is_empty()) here else A.path_of(href)
		if end {
			target == here
		} else {
			target == here or target == "/" or here.starts_with("${target}/")
		}
	}

	## A URL's path, without its query and hash, nor a trailing slash (`/lists/` is `/lists`).
	path_of : Str -> Str
	path_of = |url| {
		path =
			match url.split_first("?") {
				Ok({ before, .. }) => before
				Err(_) => url
			}
		bare =
			match path.split_first("#") {
				Ok({ before, .. }) => before
				Err(_) => path
			}
		trimmed = if (bare != "/" and bare.ends_with("/")) bare.drop_suffix("/") else bare
		if (trimmed.is_empty()) "/" else trimmed
	}
}

expect A.active("/lists/7", "/lists/7", Bool.True)
expect A.active("/lists/7?days=30", "/lists/7", Bool.True)
expect !A.active("/lists/7", "/lists", Bool.True)
expect A.active("/lists/7", "/lists", Bool.False)
expect !A.active("/listsx", "/lists", Bool.False)
expect A.active("/lists", "/", Bool.False)
expect !A.active("/lists", "/", Bool.True)
expect A.active("/", "/", Bool.True)
expect A.active("/b/3", "?card=12", Bool.True)
expect A.active("/lists/7", "/lists/7/?x=1#top", Bool.True)
