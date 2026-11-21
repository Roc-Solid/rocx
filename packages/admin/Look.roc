## The admin's pages look as the platform's own do (the jobs page, the dev mailbox: the server
## platform's `AdminHtml`): whole HTML documents under one class, `rocx-admin`, with its
## stylesheet, and a few more rules for forms, a list's filters and its pages of rows. The
## stylesheet is a copy of `AdminHtml`'s, which apps can't import yet (PROPOSALS.md).
Look := [].{

	## Text as HTML has it, in an element or an attribute's quotes.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&#39;")

	## A whole page: its title and its main part, as HTML.
	document : Str, Str -> Str
	document = |title, body| "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>${Look.escape(title)}</title><style>${Look.stylesheet}</style></head><body class=\"rocx-admin\"><main>${body}</main></body></html>"

	## The headers every page is sent with: HTML, never kept by a cache, never in another site's
	## frame, and no script, no request elsewhere, no form sent elsewhere.
	headers : List({ name : Str, value : Str })
	headers = [
		{ name: "content-type", value: "text/html; charset=utf-8" },
		{ name: "cache-control", value: "no-store" },
		{ name: "x-frame-options", value: "DENY" },
		{ name: "content-security-policy", value: "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" },
		{ name: "referrer-policy", value: "same-origin" },
	]

	## `AdminHtml`'s rules, then the admin's own.
	stylesheet : Str
	stylesheet =
		Str.join_with(
			[
				".rocx-admin{margin:0;font:14px/1.45 system-ui,-apple-system,sans-serif;color:#1f2328;background:#f6f8fa}",
				".rocx-admin main{max-width:72rem;margin:0 auto;padding:1.5rem}",
				".rocx-admin h1{font-size:1.4rem;margin:0 0 .75rem}.rocx-admin h2{font-size:1.05rem;margin:1.5rem 0 .5rem}",
				".rocx-admin a{color:#0969da;text-decoration:none}.rocx-admin a:hover{text-decoration:underline}",
				".rocx-admin nav{display:flex;flex-wrap:wrap;gap:.35rem;align-items:center;margin-bottom:1rem}",
				".rocx-admin nav a{padding:.2rem .6rem;border:1px solid #d0d7de;border-radius:2rem;background:#fff}",
				".rocx-admin nav a.on{background:#1f2328;color:#fff;border-color:#1f2328}",
				".rocx-admin table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #d0d7de;border-radius:6px}",
				".rocx-admin th,.rocx-admin td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #eaeef2;vertical-align:top}",
				".rocx-admin th{font-weight:600;color:#59636e;font-size:.8rem;text-transform:uppercase;letter-spacing:.03em}",
				".rocx-admin td.error{color:#cf222e;max-width:24rem;overflow-wrap:anywhere}",
				".rocx-admin td.actions{white-space:nowrap}.rocx-admin form{display:inline;margin:0 .15rem 0 0}",
				".rocx-admin button{font:inherit;font-size:.8rem;padding:.15rem .55rem;border:1px solid #d0d7de;border-radius:4px;background:#f6f8fa;cursor:pointer}",
				".rocx-admin button:hover{background:#eaeef2}",
				".rocx-admin .state{display:inline-block;padding:0 .5rem;border-radius:2rem;font-size:.8rem;background:#eaeef2}",
				".rocx-admin dl{display:grid;grid-template-columns:max-content 1fr;gap:.3rem 1rem;background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:.75rem 1rem}",
				".rocx-admin dt{color:#59636e}.rocx-admin dd{margin:0}",
				".rocx-admin pre{background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:.75rem;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere}",
				".rocx-admin .problem{color:#cf222e}.rocx-admin .muted{color:#59636e}",
				".rocx-admin .bar{display:flex;gap:1rem;align-items:baseline;justify-content:space-between}",
				# The admin's own.
				".rocx-admin .crumbs{margin:0 0 .5rem;color:#59636e}",
				# The list: its search and the filters' button above it; the table scrolls sideways, its
				# row of filters with it, each input as wide as its column (and at least as its kind needs).
				".rocx-admin .tools{display:flex;flex-wrap:wrap;gap:.5rem 1rem;align-items:center;margin:0 0 .75rem}",
				".rocx-admin form.search{display:flex;gap:.4rem;align-items:center;margin:0;flex:1 1 18rem;max-width:32rem}.rocx-admin form.search input{flex:1;min-width:0}",
				".rocx-admin .filtering{display:flex;gap:.75rem;align-items:center;margin-left:auto}",
				".rocx-admin form.filters{display:block;margin:0}",
				".rocx-admin .rows{overflow-x:auto;border:1px solid #d0d7de;border-radius:6px;background:#fff}.rocx-admin .rows table{border:0;border-radius:0}",
				".rocx-admin td{overflow-wrap:break-word}.rocx-admin td.null,.rocx-admin dd.null{color:#8c959f;font-style:italic}",
				".rocx-admin th a{color:inherit}.rocx-admin th a.on{color:#1f2328}",
				".rocx-admin tr.filter td{background:#f6f8fa;padding:.3rem .45rem .45rem;border-bottom:1px solid #d0d7de}",
				".rocx-admin tr.filter input,.rocx-admin tr.filter select{display:block;width:100%;min-width:6rem;font-size:.8rem;padding:.2rem .35rem}",
				".rocx-admin tr.filter input[type=number]{min-width:4.5rem}.rocx-admin tr.filter input[type=date]{min-width:8.5rem}",
				".rocx-admin tr.filter input[type=datetime-local]{min-width:12rem}.rocx-admin tr.filter input[type=time]{min-width:6rem}",
				".rocx-admin tr.filter .range{display:grid;grid-template-columns:max-content 1fr;gap:.2rem .35rem;align-items:center}",
				".rocx-admin tr.filter .range span{font-size:.7rem;color:#59636e}",
				".rocx-admin tr.filter select.nulls{margin-top:.2rem}",
				".rocx-admin tr.filter [aria-invalid=true]{border-color:#cf222e}",
				".rocx-admin tr.filter .note{display:block;margin-top:.15rem;color:#cf222e;font-size:.75rem;white-space:normal}",
				".rocx-admin td.none{padding:1rem;color:#59636e;text-align:center}",
				".rocx-admin input,.rocx-admin select,.rocx-admin textarea{font:inherit;padding:.3rem .45rem;border:1px solid #d0d7de;border-radius:4px;background:#fff;color:inherit;box-sizing:border-box}",
				".rocx-admin textarea{width:100%;min-height:5rem}.rocx-admin textarea.code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85rem}",
				".rocx-admin form.edit{display:block}",
				".rocx-admin .fields{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.7rem 1rem;align-items:start;background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:1rem}",
				".rocx-admin .fields>label,.rocx-admin .fields>span.label{padding-top:.3rem;font-weight:600}",
				".rocx-admin .fields input:not([type=checkbox]),.rocx-admin .fields select{width:100%;max-width:32rem}",
				".rocx-admin .help{display:block;color:#59636e;font-size:.8rem;margin-top:.2rem}",
				".rocx-admin .value{display:block;padding-top:.3rem;white-space:pre-wrap;overflow-wrap:anywhere}",
				".rocx-admin .buttons{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin-top:1rem}",
				".rocx-admin .buttons button{font-size:.9rem;padding:.3rem .8rem}",
				".rocx-admin button.primary{background:#1f883d;border-color:#1a7f37;color:#fff}.rocx-admin button.primary:hover{background:#1a7f37}",
				".rocx-admin button.danger{color:#cf222e}.rocx-admin button.danger:hover{background:#ffebe9}",
				".rocx-admin .notice{background:#dafbe1;color:#1a7f37;border:1px solid #aceebb;border-radius:6px;padding:.5rem .75rem;margin:0 0 1rem}",
				".rocx-admin p.problem{background:#ffebe9;border:1px solid #ffcecb;border-radius:6px;padding:.5rem .75rem}",
				".rocx-admin nav.pager{margin:.75rem 0 0}.rocx-admin nav.pager .gap{color:#59636e}",
			],
			"",
		)
}

expect Look.escape("<a href=\"x\">'&") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;"
expect Look.document("A <b>", "<p>hi</p>").contains("<title>A &lt;b&gt;</title>")
