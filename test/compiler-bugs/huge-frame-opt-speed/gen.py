# Writes Bad.roc: a page as rocx's Root renders one (D-040): the route a memo of the path, a layout
# given the page's meta as a getter, an <Errored> around a keyed part (Html.switched) that makes the
# page the route names, one of PAGES components, each ITEMS list items with holes that read a signal
# and a prop (getters, D-039).
import os, sys
# PLATFORM: the server platform's main.roc (any path; Roc wants it relative, so it is made so).
platform = os.environ.get('PLATFORM', '../../../server/platform/main.roc')
if os.path.isabs(platform):
    platform = os.path.relpath(os.path.realpath(platform), os.path.realpath('.'))
pages = int(sys.argv[1]) if len(sys.argv) > 1 else 60
items = int(sys.argv[2]) if len(sys.argv) > 2 else 40
toc = int(sys.argv[3]) if len(sys.argv) > 3 else 10
# WIDE=N gives each page a hole whose closure captures a record of N strings (24 bytes each). A
# closure's size is its lambda set's largest captures', so every `() => Str` the platform's Html
# holds, and so every Html value (a list literal's element, a child), is that big: the docs site's
# Html values are 2,304 bytes so. 0 (the default) adds none.
wide = int(os.environ.get('WIDE') or '0')
# FANOUT=K puts the items in a tree of lists of at most K (default 0: one list of all of them). A
# list literal's elements are all alive until the list is made, so one long list needs a slot for each
# element at once, whatever the backend does; a tree needs few at once, so its frame shows whether
# the slots of the values made one after another are shared.
fanout = int(os.environ.get('FANOUT') or '0')
# SHAPES=mixed gives the holes six different bodies (by the item's number), which LLVM can't fold into
# one as it folds the same body with other constants (the default: every hole alike but its numbers).
mixed = os.environ.get('SHAPES', 'same') == 'mixed'
def attr_hole(p, i):
    if not mixed: return f'(count!() + {i}).to_str()'
    return [
        f'(count!() + {i}).to_str()',
        f'"${{(count!() * {i + 1}).to_str()}}/${{count!().to_str()}}"',
        f'Str.join_with([count!().to_str(), "{p}", "{i}"], "-")',
        f'if (count!() > {i}) "over-${{count!().to_str()}}" else "under-{i}"',
        f'count!().to_str().concat("-{p}-{i}")',
        f'Str.repeat("n", count!() % {i + 2})',
    ][i % 6]
def text_hole(p, i):
    if not mixed: return f'"Item {i} of ${{count!().to_str()}}"'
    return [
        f'"Item {i} of ${{count!().to_str()}}"',
        f'"${{count!().to_str()}} and ${{(count!() + {i}).to_str()}} of page {p}"',
        f'Str.join_with(["a", count!().to_str(), "b{i}"], " ")',
        f'if (count!() % 2 == 0) "even ${{count!().to_str()}}" else "odd {i}"',
        f'Str.repeat("*", count!() % {i + 3}).concat(" {i}")',
        f'"${{"Item"}} {i}: ${{(count!() - {p}).to_str()}}"',
    ][i % 6]
out = []
w = out.append
w(f'app [program] {{ pf: platform "{platform}" }}')
w('')
w('import pf.Html')
w('import pf.Server')
w('import pf.Solid')
w('import pf.Errored')
w('')
for p in range(pages):
    w(f'## Page {p}: its title, a count, and {items} items, each with holes.')
    w(f'Page{p} := [].{{')
    w(f'\tmeta = {{ title: "Page {p}", description: "The page number {p}, described at some length as a page is", toc: [' + ', '.join(f'{{ id: "s{p}-{t}", label: "Section {t} of page {p}" }}' for t in range(toc)) + '] }')
    w('')
    w(f'\tview! : {{ params : () -> {{}} }} => Html')
    w(f'\tview! = |{{ params: _ }}| {{')
    w(f'\t\t(count!, _set_count!) = Solid.create_signal!({p}.U64)')
    if wide:
        w('\t\twide = { ' + ', '.join(f'f{k}: "${{count!().to_str()}}.{k}"' for k in range(wide)) + ' }')
    w('\t\tHtml.element("section", [], [')
    w(f'\t\t\tHtml.element("h1", [], [Html.text("Page {p}")]),')
    if wide:
        w('\t\t\tHtml.element("p", [], [Html.text_of(|| Str.join_with([' + ', '.join(f'wide.f{k}' for k in range(wide)) + '], count!().to_str()))]),')
    lis = [f'Html.element("li", [Html.attr("class", "item-{p}-{i}"), Html.attr_of("data-n", || {attr_hole(p, i)})], [Html.element("b", [], [Html.text_of(|| {text_hole(p, i)})]), Html.element("a", [Html.attr("href", "/{p}/{i}")], [Html.text("more")])])' for i in range(items)]
    if fanout:
        # The items as a tree, FANOUT children an element: no list holds more than FANOUT values.
        level = lis
        while len(level) > fanout:
            level = [f'Html.element("ul", [], [{", ".join(level[k:k + fanout])}])' for k in range(0, len(level), fanout)]
        lis = level
    w('\t\t\tHtml.element("ul", [], [')
    for li in lis:
        w(f'\t\t\t\t{li},')
    w('\t\t\t]),')
    w('\t\t])')
    w('\t}')
    w('}')
    w('')
w('Route : [' + ', '.join(f'P{p}' for p in range(pages)) + ', Missing(Str)]')
w('')
w('route : Str -> Route')
w('route = |path|')
w('\t' + ''.join(f'if (path == "/{p}") P{p} else ' for p in range(pages)) + 'Missing(path)')
w('')
w('meta_of = |at|')
w('\tmatch at {')
for p in range(pages):
    w(f'\t\tP{p} => Page{p}.meta')
w('\t\tMissing(_) => { title: "None", description: "Nothing here", toc: [] }')
w('\t}')
w('')
w('key_of : Route -> Str')
w('key_of = |at|')
w('\tmatch at {')
for p in range(pages):
    w(f'\t\tP{p} => "/{p}"')
w('\t\tMissing(path) => "404 ${path}"')
w('\t}')
w('')
w('## The layout: the document, its title the page meta\'s (a getter).')
w('layout! : { meta : () => { title : Str, description : Str, toc : List({ id : Str, label : Str }) }, children : List(Html) } => Html')
w('layout! = |{ meta, children }|')
w('\tHtml.element("html", [], [Html.element("head", [], [Html.element("title", [], [Html.text_of(|| meta().title)]), Html.void("meta", [Html.attr_of("content", || meta().description)])]), Html.element("body", [], [Html.element("main", [], children), Html.element("aside", [], [Html.list_of(|| meta().toc.map(|link| Html.element("a", [Html.attr("href", "#${link.id}")], [Html.text(link.label)])))])])])')
w('')
w('level! : (() => Route) => Html')
w('level! = |route!| Html.switched(|| Ok(key_of(route!())), || made!(route!), Html.empty({}))')
w('')
w('made! : (() => Route) => Html')
w('made! = |route!|')
w('\tmatch route!() {')
for p in range(pages):
    w(f'\t\tP{p} => Html.component(|| Page{p}.view!({{ params: || {{}} }}))')
w('\t\tMissing(path) => Html.text("nothing at ${path}")')
w('\t}')
w('')
w('render! : Str => Html')
w('render! = |path| {')
w('\troute! = Solid.create_memo!(|| route(path))')
w('\tHtml.component(|| layout!({ meta: || meta_of(route!()), children: [Errored.view!({ fallback: |problem, _retry| Html.text(problem), children: [level!(route!)] })] }))')
w('}')
w('')
w('program = {')
w('\tinit!: |started| Ok(started),')
w('\trespond!: |request, _started| { status: 200, headers: [], body: Page(|{}| render!(request.path)) },')
w('\tdatabase: Postgres,')
w('\tmigrations: [],')
w('\tactors: [],')
w('\tlogs: { format: Auto },')
w('\tplugins: [],')
w('\troutes: [],')
w('}')
open('Bad.roc', 'w').write('\n'.join(out) + '\n')
