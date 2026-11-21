import Md

## Examples from the specs, each an `expect`: Markdown in, the HTML the spec says out. The
## examples are the specs' own: CommonMark 0.31.2 (https://spec.commonmark.org/0.31.2/, by John
## MacFarlane, CC BY-SA 4.0) and GitHub Flavored Markdown 0.29-gfm
## (https://github.github.com/gfm/, CC BY-SA 4.0). The specs' HTML passes raw HTML through, so
## these render with `raw: Trusted`.
##
## Not every example is here: the first of each of CommonMark's sections and every fourth one
## after it, and all of GFM's for its extensions but the tag filter (which `Trusted` doesn't
## apply). All of CommonMark's 652 pass but three, where GitHub's bare links (`www.…`,
## `https://…`, `someone@example.com`) make links of what CommonMark leaves as text.
Spec := [].{}

html : Str -> Str
html = |source| Md.to_html_with(Md.parse(source), { raw: Trusted })

# Tabs
expect html("\tfoo\tbaz\t\tbim\n") == "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n" # 1
expect html("  - foo\n\n\tbar\n") == "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n" # 4
expect html("    foo\n\tbar\n") == "<pre><code>foo\nbar\n</code></pre>\n" # 8

# Backslash escapes
expect html("\\!\\\"\\#\\\$\\%\\&\\'\\(\\)\\*\\+\\,\\-\\.\\/\\:\\;\\<\\=\\>\\?\\@\\[\\\\\\]\\^\\_\\`\\{\\|\\}\\~\n") == "<p>!&quot;#\$%&amp;'()*+,-./:;&lt;=&gt;?@[\\]^_`{|}~</p>\n" # 12
expect html("\\\\*emphasis*\n") == "<p>\\<em>emphasis</em></p>\n" # 15
expect html("~~~\n\\[\\]\n~~~\n") == "<pre><code>\\[\\]\n</code></pre>\n" # 19
expect html("[foo]\n\n[foo]: /bar\\* \"ti\\*tle\"\n") == "<p><a href=\"/bar*\" title=\"ti*tle\">foo</a></p>\n" # 23

# Entity and numeric character references
expect html("&nbsp; &amp; &copy; &AElig; &Dcaron;\n&frac34; &HilbertSpace; &DifferentialD;\n&ClockwiseContourIntegral; &ngE;\n") == "<p>  &amp; © Æ Ď\n¾ ℋ ⅆ\n∲ ≧̸</p>\n" # 25
expect html("&nbsp &x; &#; &#x;\n&#87654321;\n&#abcdef0;\n&ThisIsNotDefined; &hi?;\n") == "<p>&amp;nbsp &amp;x; &amp;#; &amp;#x;\n&amp;#87654321;\n&amp;#abcdef0;\n&amp;ThisIsNotDefined; &amp;hi?;</p>\n" # 28
expect html("[foo](/f&ouml;&ouml; \"f&ouml;&ouml;\")\n") == "<p><a href=\"/f%C3%B6%C3%B6\" title=\"föö\">foo</a></p>\n" # 32
expect html("    f&ouml;f&ouml;\n") == "<pre><code>f&amp;ouml;f&amp;ouml;\n</code></pre>\n" # 36
expect html("&#9;foo\n") == "<p>\tfoo</p>\n" # 40

# Precedence
expect html("- `one\n- two`\n") == "<ul>\n<li>`one</li>\n<li>two`</li>\n</ul>\n" # 42

# Thematic breaks
expect html("***\n---\n___\n") == "<hr />\n<hr />\n<hr />\n" # 43
expect html("--\n**\n__\n") == "<p>--\n**\n__</p>\n" # 46
expect html("_____________________________________\n") == "<hr />\n" # 50
expect html("- - - -    \n") == "<hr />\n" # 54
expect html("Foo\n***\nbar\n") == "<p>Foo</p>\n<hr />\n<p>bar</p>\n" # 58

# ATX headings
expect html("# foo\n## foo\n### foo\n#### foo\n##### foo\n###### foo\n") == "<h1>foo</h1>\n<h2>foo</h2>\n<h3>foo</h3>\n<h4>foo</h4>\n<h5>foo</h5>\n<h6>foo</h6>\n" # 62
expect html("\\## foo\n") == "<p>## foo</p>\n" # 65
expect html("    # foo\n") == "<pre><code># foo\n</code></pre>\n" # 69
expect html("### foo ###     \n") == "<h3>foo</h3>\n" # 73
expect html("****\n## foo\n****\n") == "<hr />\n<h2>foo</h2>\n<hr />\n" # 77

# Setext headings
expect html("Foo *bar*\n=========\n\nFoo *bar*\n---------\n") == "<h1>Foo <em>bar</em></h1>\n<h2>Foo <em>bar</em></h2>\n" # 80
expect html("Foo\n-------------------------\n\nFoo\n=\n") == "<h2>Foo</h2>\n<h1>Foo</h1>\n" # 83
expect html("Foo\n    ---\n") == "<p>Foo\n---</p>\n" # 87
expect html("`Foo\n----\n`\n\n<a title=\"a lot\n---\nof dashes\"/>\n") == "<h2>`Foo</h2>\n<p>`</p>\n<h2>&lt;a title=&quot;a lot</h2>\n<p>of dashes&quot;/&gt;</p>\n" # 91
expect html("Foo\nBar\n---\n") == "<h2>Foo\nBar</h2>\n" # 95
expect html("- foo\n-----\n") == "<ul>\n<li>foo</li>\n</ul>\n<hr />\n" # 99
expect html("Foo\n\nbar\n---\nbaz\n") == "<p>Foo</p>\n<h2>bar</h2>\n<p>baz</p>\n" # 103

# Indented code blocks
expect html("    a simple\n      indented code block\n") == "<pre><code>a simple\n  indented code block\n</code></pre>\n" # 107
expect html("    <a/>\n    *hi*\n\n    - one\n") == "<pre><code>&lt;a/&gt;\n*hi*\n\n- one\n</code></pre>\n" # 110
expect html("    foo\nbar\n") == "<pre><code>foo\n</code></pre>\n<p>bar</p>\n" # 114
expect html("    foo  \n") == "<pre><code>foo  \n</code></pre>\n" # 118

# Fenced code blocks
expect html("```\n<\n >\n```\n") == "<pre><code>&lt;\n &gt;\n</code></pre>\n" # 119
expect html("```\naaa\n~~~\n```\n") == "<pre><code>aaa\n~~~\n</code></pre>\n" # 122
expect html("```\n") == "<pre><code></code></pre>\n" # 126
expect html("```\n```\n") == "<pre><code></code></pre>\n" # 130
expect html("    ```\n    aaa\n    ```\n") == "<pre><code>```\naaa\n```\n</code></pre>\n" # 134
expect html("``` ```\naaa\n") == "<p><code> </code>\naaa</p>\n" # 138
expect html("```ruby\ndef foo(x)\n  return 3\nend\n```\n") == "<pre><code class=\"language-ruby\">def foo(x)\n  return 3\nend\n</code></pre>\n" # 142
expect html("~~~ aa ``` ~~~\nfoo\n~~~\n") == "<pre><code class=\"language-aa\">foo\n</code></pre>\n" # 146

# HTML blocks
expect html("<table><tr><td>\n<pre>\n**Hello**,\n\n_world_.\n</pre>\n</td></tr></table>\n") == "<table><tr><td>\n<pre>\n**Hello**,\n<p><em>world</em>.\n</pre></p>\n</td></tr></table>\n" # 148
expect html("</div>\n*foo*\n") == "</div>\n*foo*\n" # 151
expect html("<div>\n*foo*\n\n*bar*\n") == "<div>\n*foo*\n<p><em>bar</em></p>\n" # 155
expect html("<div><a href=\"bar\">*foo*</a></div>\n") == "<div><a href=\"bar\">*foo*</a></div>\n" # 159
expect html("<Warning>\n*bar*\n</Warning>\n") == "<Warning>\n*bar*\n</Warning>\n" # 163
expect html("<del>\n\n*foo*\n\n</del>\n") == "<del>\n<p><em>foo</em></p>\n</del>\n" # 167
expect html("<textarea>\n\n*foo*\n\n_bar_\n\n</textarea>\n") == "<textarea>\n\n*foo*\n\n_bar_\n\n</textarea>\n" # 171
expect html("- <div>\n- foo\n") == "<ul>\n<li>\n<div>\n</li>\n<li>foo</li>\n</ul>\n" # 175
expect html("<!-- Foo\n\nbar\n   baz -->\nokay\n") == "<!-- Foo\n\nbar\n   baz -->\n<p>okay</p>\n" # 179
expect html("  <!-- foo -->\n\n    <!-- foo -->\n") == "  <!-- foo -->\n<pre><code>&lt;!-- foo --&gt;\n</code></pre>\n" # 183
expect html("Foo\n<a href=\"bar\">\nbaz\n") == "<p>Foo\n<a href=\"bar\">\nbaz</p>\n" # 187
expect html("<table>\n\n  <tr>\n\n    <td>\n      Hi\n    </td>\n\n  </tr>\n\n</table>\n") == "<table>\n  <tr>\n<pre><code>&lt;td&gt;\n  Hi\n&lt;/td&gt;\n</code></pre>\n  </tr>\n</table>\n" # 191

# Link reference definitions
expect html("[foo]: /url \"title\"\n\n[foo]\n") == "<p><a href=\"/url\" title=\"title\">foo</a></p>\n" # 192
expect html("[Foo bar]:\n<my url>\n'title'\n\n[Foo bar]\n") == "<p><a href=\"my%20url\" title=\"title\">Foo bar</a></p>\n" # 195
expect html("[foo]:\n\n[foo]\n") == "<p>[foo]:</p>\n<p>[foo]</p>\n" # 199
expect html("[foo]\n\n[foo]: url\n") == "<p><a href=\"url\">foo</a></p>\n" # 203
expect html("[foo]: /url\n") == "" # 207
expect html("    [foo]: /url \"title\"\n\n[foo]\n") == "<pre><code>[foo]: /url &quot;title&quot;\n</code></pre>\n<p>[foo]</p>\n" # 211
expect html("[foo]: /url\nbar\n===\n[foo]\n") == "<h1>bar</h1>\n<p><a href=\"/url\">foo</a></p>\n" # 215

# Paragraphs
expect html("aaa\n\nbbb\n") == "<p>aaa</p>\n<p>bbb</p>\n" # 219
expect html("  aaa\n bbb\n") == "<p>aaa\nbbb</p>\n" # 222
expect html("aaa     \nbbb     \n") == "<p>aaa<br />\nbbb</p>\n" # 226

# Blank lines
expect html("  \n\naaa\n  \n\n# aaa\n\n  \n") == "<p>aaa</p>\n<h1>aaa</h1>\n" # 227

# Block quotes
expect html("> # Foo\n> bar\n> baz\n") == "<blockquote>\n<h1>Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n" # 228
expect html("    > # Foo\n    > bar\n    > baz\n") == "<pre><code>&gt; # Foo\n&gt; bar\n&gt; baz\n</code></pre>\n" # 231
expect html("> - foo\n- bar\n") == "<blockquote>\n<ul>\n<li>foo</li>\n</ul>\n</blockquote>\n<ul>\n<li>bar</li>\n</ul>\n" # 235
expect html(">\n") == "<blockquote>\n</blockquote>\n" # 239
expect html("> foo\n> bar\n") == "<blockquote>\n<p>foo\nbar</p>\n</blockquote>\n" # 243
expect html("> bar\nbaz\n") == "<blockquote>\n<p>bar\nbaz</p>\n</blockquote>\n" # 247
expect html(">>> foo\n> bar\n>>baz\n") == "<blockquote>\n<blockquote>\n<blockquote>\n<p>foo\nbar\nbaz</p>\n</blockquote>\n</blockquote>\n</blockquote>\n" # 251

# List items
expect html("A paragraph\nwith two lines.\n\n    indented code\n\n> A block quote.\n") == "<p>A paragraph\nwith two lines.</p>\n<pre><code>indented code\n</code></pre>\n<blockquote>\n<p>A block quote.</p>\n</blockquote>\n" # 253
expect html("- one\n\n  two\n") == "<ul>\n<li>\n<p>one</p>\n<p>two</p>\n</li>\n</ul>\n" # 256
expect html(">>- one\n>>\n  >  > two\n") == "<blockquote>\n<blockquote>\n<ul>\n<li>one</li>\n</ul>\n<p>two</p>\n</blockquote>\n</blockquote>\n" # 260
expect html("- Foo\n\n      bar\n\n\n      baz\n") == "<ul>\n<li>\n<p>Foo</p>\n<pre><code>bar\n\n\nbaz\n</code></pre>\n</li>\n</ul>\n" # 264
expect html("003. ok\n") == "<ol start=\"3\">\n<li>ok</li>\n</ol>\n" # 268
expect html("    indented code\n\nparagraph\n\n    more code\n") == "<pre><code>indented code\n</code></pre>\n<p>paragraph</p>\n<pre><code>more code\n</code></pre>\n" # 272
expect html("-    foo\n\n  bar\n") == "<ul>\n<li>foo</li>\n</ul>\n<p>bar</p>\n" # 276
expect html("-\n\n  foo\n") == "<ul>\n<li></li>\n</ul>\n<p>foo</p>\n" # 280
expect html("*\n") == "<ul>\n<li></li>\n</ul>\n" # 284
expect html("   1.  A paragraph\n       with two lines.\n\n           indented code\n\n       > A block quote.\n") == "<ol>\n<li>\n<p>A paragraph\nwith two lines.</p>\n<pre><code>indented code\n</code></pre>\n<blockquote>\n<p>A block quote.</p>\n</blockquote>\n</li>\n</ol>\n" # 288
expect html("> 1. > Blockquote\ncontinued here.\n") == "<blockquote>\n<ol>\n<li>\n<blockquote>\n<p>Blockquote\ncontinued here.</p>\n</blockquote>\n</li>\n</ol>\n</blockquote>\n" # 292
expect html("10) foo\n    - bar\n") == "<ol start=\"10\">\n<li>foo\n<ul>\n<li>bar</li>\n</ul>\n</li>\n</ol>\n" # 296
expect html("- # Foo\n- Bar\n  ---\n  baz\n") == "<ul>\n<li>\n<h1>Foo</h1>\n</li>\n<li>\n<h2>Bar</h2>\nbaz</li>\n</ul>\n" # 300

# Lists
expect html("- foo\n- bar\n+ baz\n") == "<ul>\n<li>foo</li>\n<li>bar</li>\n</ul>\n<ul>\n<li>baz</li>\n</ul>\n" # 301
expect html("The number of windows in my house is\n14.  The number of doors is 6.\n") == "<p>The number of windows in my house is\n14.  The number of doors is 6.</p>\n" # 304
expect html("- foo\n- bar\n\n<!-- -->\n\n- baz\n- bim\n") == "<ul>\n<li>foo</li>\n<li>bar</li>\n</ul>\n<!-- -->\n<ul>\n<li>baz</li>\n<li>bim</li>\n</ul>\n" # 308
expect html("- a\n - b\n  - c\n   - d\n    - e\n") == "<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n<li>d\n- e</li>\n</ul>\n" # 312
expect html("- a\n- b\n\n  c\n- d\n") == "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n<p>c</p>\n</li>\n<li>\n<p>d</p>\n</li>\n</ul>\n" # 316
expect html("* a\n  > b\n  >\n* c\n") == "<ul>\n<li>a\n<blockquote>\n<p>b</p>\n</blockquote>\n</li>\n<li>c</li>\n</ul>\n" # 320
expect html("1. ```\n   foo\n   ```\n\n   bar\n") == "<ol>\n<li>\n<pre><code>foo\n</code></pre>\n<p>bar</p>\n</li>\n</ol>\n" # 324

# Inlines
expect html("`hi`lo`\n") == "<p><code>hi</code>lo`</p>\n" # 327

# Code spans
expect html("`foo`\n") == "<p><code>foo</code></p>\n" # 328
expect html("`  ``  `\n") == "<p><code> `` </code></p>\n" # 331
expect html("``\nfoo\nbar  \nbaz\n``\n") == "<p><code>foo bar   baz</code></p>\n" # 335
expect html("``foo`bar``\n") == "<p><code>foo`bar</code></p>\n" # 339
expect html("`<a href=\"`\">`\n") == "<p><code>&lt;a href=&quot;</code>&quot;&gt;`</p>\n" # 343
expect html("```foo``\n") == "<p>```foo``</p>\n" # 347

# Emphasis and strong emphasis
expect html("*foo bar*\n") == "<p><em>foo bar</em></p>\n" # 350
expect html("* a *\n") == "<p>* a *</p>\n" # 353
expect html("_foo bar_\n") == "<p><em>foo bar</em></p>\n" # 357
expect html("5_6_78\n") == "<p>5_6_78</p>\n" # 361
expect html("_foo*\n") == "<p>_foo*</p>\n" # 365
expect html("*(*foo*)*\n") == "<p><em>(<em>foo</em>)</em></p>\n" # 369
expect html("_(_foo_)_\n") == "<p><em>(<em>foo</em>)</em></p>\n" # 373
expect html("_(bar)_.\n") == "<p><em>(bar)</em>.</p>\n" # 377
expect html("foo**bar**\n") == "<p>foo<strong>bar</strong></p>\n" # 381
expect html("a__\"foo\"__\n") == "<p>a__&quot;foo&quot;__</p>\n" # 385
expect html("__foo, __bar__, baz__\n") == "<p><strong>foo, <strong>bar</strong>, baz</strong></p>\n" # 389
expect html("*(**foo**)*\n") == "<p><em>(<strong>foo</strong>)</em></p>\n" # 393
expect html("__foo bar __\n") == "<p>__foo bar __</p>\n" # 397
expect html("__пристаням__стремятся\n") == "<p>__пристаням__стремятся</p>\n" # 401
expect html("*foo\nbar*\n") == "<p><em>foo\nbar</em></p>\n" # 405
expect html("*foo *bar**\n") == "<p><em>foo <em>bar</em></em></p>\n" # 409
expect html("***foo** bar*\n") == "<p><em><strong>foo</strong> bar</em></p>\n" # 413
expect html("foo******bar*********baz\n") == "<p>foo<strong><strong><strong>bar</strong></strong></strong>***baz</p>\n" # 417
expect html("**** is not an empty strong emphasis\n") == "<p>**** is not an empty strong emphasis</p>\n" # 421
expect html("__foo __bar__ baz__\n") == "<p><strong>foo <strong>bar</strong> baz</strong></p>\n" # 425
expect html("**foo*bar*baz**\n") == "<p><strong>foo<em>bar</em>baz</strong></p>\n" # 429
expect html("**foo [*bar*](/url)**\n") == "<p><strong>foo <a href=\"/url\"><em>bar</em></a></strong></p>\n" # 433
expect html("foo *\\**\n") == "<p>foo <em>*</em></p>\n" # 437
expect html("foo **_**\n") == "<p>foo <strong>_</strong></p>\n" # 441
expect html("****foo*\n") == "<p>***<em>foo</em></p>\n" # 445
expect html("foo _\\__\n") == "<p>foo <em>_</em></p>\n" # 449
expect html("foo __*__\n") == "<p>foo <strong>*</strong></p>\n" # 453
expect html("____foo_\n") == "<p>___<em>foo</em></p>\n" # 457
expect html("*_foo_*\n") == "<p><em><em>foo</em></em></p>\n" # 461
expect html("____foo____\n") == "<p><strong><strong>foo</strong></strong></p>\n" # 465
expect html("*foo _bar* baz_\n") == "<p><em>foo _bar</em> baz_</p>\n" # 469
expect html("*[bar*](/url)\n") == "<p>*<a href=\"/url\">bar*</a></p>\n" # 473
expect html("__<a href=\"__\">\n") == "<p>__<a href=\"__\"></p>\n" # 477
expect html("__a<https://foo.bar/?q=__>\n") == "<p>__a<a href=\"https://foo.bar/?q=__\">https://foo.bar/?q=__</a></p>\n" # 481

# Links
expect html("[link](/uri \"title\")\n") == "<p><a href=\"/uri\" title=\"title\">link</a></p>\n" # 482
expect html("[link]()\n") == "<p><a href=\"\">link</a></p>\n" # 485
expect html("[link](</my uri>)\n") == "<p><a href=\"/my%20uri\">link</a></p>\n" # 489
expect html("[link](<foo\\>)\n") == "<p>[link](&lt;foo&gt;)</p>\n" # 493
expect html("[link](foo(and(bar))\n") == "<p>[link](foo(and(bar))</p>\n" # 497
expect html("[link](#fragment)\n\n[link](https://example.com#fragment)\n\n[link](https://example.com?foo=3#frag)\n") == "<p><a href=\"#fragment\">link</a></p>\n<p><a href=\"https://example.com#fragment\">link</a></p>\n<p><a href=\"https://example.com?foo=3#frag\">link</a></p>\n" # 501
expect html("[link](/url \"title\")\n[link](/url 'title')\n[link](/url (title))\n") == "<p><a href=\"/url\" title=\"title\">link</a>\n<a href=\"/url\" title=\"title\">link</a>\n<a href=\"/url\" title=\"title\">link</a></p>\n" # 505
expect html("[link](/url 'title \"and\" title')\n") == "<p><a href=\"/url\" title=\"title &quot;and&quot; title\">link</a></p>\n" # 509
expect html("[link] bar](/uri)\n") == "<p>[link] bar](/uri)</p>\n" # 513
expect html("[![moon](moon.jpg)](/uri)\n") == "<p><a href=\"/uri\"><img src=\"moon.jpg\" alt=\"moon\" /></a></p>\n" # 517
expect html("*[foo*](/uri)\n") == "<p>*<a href=\"/uri\">foo*</a></p>\n" # 521
expect html("[foo`](/uri)`\n") == "<p>[foo<code>](/uri)</code></p>\n" # 525
expect html("[link \\[bar][ref]\n\n[ref]: /uri\n") == "<p><a href=\"/uri\">link [bar</a></p>\n" # 529
expect html("[foo *bar [baz][ref]*][ref]\n\n[ref]: /uri\n") == "<p>[foo <em>bar <a href=\"/uri\">baz</a></em>]<a href=\"/uri\">ref</a></p>\n" # 533
expect html("[foo`][ref]`\n\n[ref]: /uri\n") == "<p>[foo<code>][ref]</code></p>\n" # 537
expect html("[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n") == "<p><a href=\"/url\">Baz</a></p>\n" # 541
expect html("[bar][foo\\!]\n\n[foo!]: /url\n") == "<p>[bar][foo!]</p>\n" # 545
expect html("[foo][ref\\[]\n\n[ref\\[]: /uri\n") == "<p><a href=\"/uri\">foo</a></p>\n" # 549
expect html("[foo][]\n\n[foo]: /url \"title\"\n") == "<p><a href=\"/url\" title=\"title\">foo</a></p>\n" # 553
expect html("[foo]\n\n[foo]: /url \"title\"\n") == "<p><a href=\"/url\" title=\"title\">foo</a></p>\n" # 557
expect html("[Foo]\n\n[foo]: /url \"title\"\n") == "<p><a href=\"/url\" title=\"title\">Foo</a></p>\n" # 561
expect html("[foo][bar]\n\n[foo]: /url1\n[bar]: /url2\n") == "<p><a href=\"/url2\">foo</a></p>\n" # 565
expect html("[foo][bar][baz]\n\n[baz]: /url\n") == "<p>[foo]<a href=\"/url\">bar</a></p>\n" # 569

# Images
expect html("![foo](/url \"title\")\n") == "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n" # 572
expect html("![foo [bar](/url)](/url2)\n") == "<p><img src=\"/url2\" alt=\"foo bar\" /></p>\n" # 575
expect html("My ![foo bar](/path/to/train.jpg  \"title\"   )\n") == "<p>My <img src=\"/path/to/train.jpg\" alt=\"foo bar\" title=\"title\" /></p>\n" # 579
expect html("![foo][bar]\n\n[BAR]: /url\n") == "<p><img src=\"/url\" alt=\"foo\" /></p>\n" # 583
expect html("![foo] \n[]\n\n[foo]: /url \"title\"\n") == "<p><img src=\"/url\" alt=\"foo\" title=\"title\" />\n[]</p>\n" # 587
expect html("![Foo]\n\n[foo]: /url \"title\"\n") == "<p><img src=\"/url\" alt=\"Foo\" title=\"title\" /></p>\n" # 591

# Autolinks
expect html("<http://foo.bar.baz>\n") == "<p><a href=\"http://foo.bar.baz\">http://foo.bar.baz</a></p>\n" # 594
expect html("<MAILTO:FOO@BAR.BAZ>\n") == "<p><a href=\"MAILTO:FOO@BAR.BAZ\">MAILTO:FOO@BAR.BAZ</a></p>\n" # 597
expect html("<localhost:5001/foo>\n") == "<p><a href=\"localhost:5001/foo\">localhost:5001/foo</a></p>\n" # 601
expect html("<foo+special@Bar.baz-bar0.com>\n") == "<p><a href=\"mailto:foo+special@Bar.baz-bar0.com\">foo+special@Bar.baz-bar0.com</a></p>\n" # 605
expect html("<m:abc>\n") == "<p>&lt;m:abc&gt;</p>\n" # 609

# Raw HTML
expect html("<a><bab><c2c>\n") == "<p><a><bab><c2c></p>\n" # 613
expect html("<a foo=\"bar\" bam = 'baz <em>\"</em>'\n_boolean zoop:33=zoop:33 />\n") == "<p><a foo=\"bar\" bam = 'baz <em>\"</em>'\n_boolean zoop:33=zoop:33 /></p>\n" # 616
expect html("<a href=\"hi'> <a href=hi'>\n") == "<p>&lt;a href=&quot;hi'&gt; &lt;a href=hi'&gt;</p>\n" # 620
expect html("</a href=\"foo\">\n") == "<p>&lt;/a href=&quot;foo&quot;&gt;</p>\n" # 624
expect html("foo <!ELEMENT br EMPTY>\n") == "<p>foo <!ELEMENT br EMPTY></p>\n" # 628
expect html("<a href=\"\\\"\">\n") == "<p>&lt;a href=&quot;&quot;&quot;&gt;</p>\n" # 632

# Hard line breaks
expect html("foo  \nbaz\n") == "<p>foo<br />\nbaz</p>\n" # 633
expect html("foo  \n     bar\n") == "<p>foo<br />\nbar</p>\n" # 636
expect html("`code  \nspan`\n") == "<p><code>code   span</code></p>\n" # 640
expect html("foo\\\n") == "<p>foo\\</p>\n" # 644

# Soft line breaks
expect html("foo\nbaz\n") == "<p>foo\nbaz</p>\n" # 648

# Textual content
expect html("hello \$.;'there\n") == "<p>hello \$.;'there</p>\n" # 650

# GFM: Tables
expect html("| foo | bar |\n| --- | --- |\n| baz | bim |\n") == "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n" # GFM 198
expect html("| abc | defghi |\n:-: | -----------:\nbar | baz\n") == "<table>\n<thead>\n<tr>\n<th align=\"center\">abc</th>\n<th align=\"right\">defghi</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"center\">bar</td>\n<td align=\"right\">baz</td>\n</tr>\n</tbody>\n</table>\n" # GFM 199
expect html("| f\\|oo  |\n| ------ |\n| b `\\|` az |\n| b **\\|** im |\n") == "<table>\n<thead>\n<tr>\n<th>f|oo</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>b <code>|</code> az</td>\n</tr>\n<tr>\n<td>b <strong>|</strong> im</td>\n</tr>\n</tbody>\n</table>\n" # GFM 200
expect html("| abc | def |\n| --- | --- |\n| bar | baz |\n> bar\n") == "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n<blockquote>\n<p>bar</p>\n</blockquote>\n" # GFM 201
expect html("| abc | def |\n| --- | --- |\n| bar | baz |\nbar\n\nbar\n") == "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n</tbody>\n</table>\n<p>bar</p>\n" # GFM 202
expect html("| abc | def |\n| --- |\n| bar |\n") == "<p>| abc | def |\n| --- |\n| bar |</p>\n" # GFM 203
expect html("| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |\n") == "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n" # GFM 204
expect html("| abc | def |\n| --- | --- |\n") == "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n</table>\n" # GFM 205

# GFM: Task list items
expect html("- [ ] foo\n- [x] bar\n") == "<ul>\n<li><input disabled=\"\" type=\"checkbox\"> foo</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> bar</li>\n</ul>\n" # GFM 279
expect html("- [x] foo\n  - [ ] bar\n  - [x] baz\n- [ ] bim\n") == "<ul>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> foo\n<ul>\n<li><input disabled=\"\" type=\"checkbox\"> bar</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> baz</li>\n</ul>\n</li>\n<li><input disabled=\"\" type=\"checkbox\"> bim</li>\n</ul>\n" # GFM 280

# GFM: Strikethrough
expect html("~~Hi~~ Hello, world!\n") == "<p><del>Hi</del> Hello, world!</p>\n" # GFM 491
expect html("This ~~has a\n\nnew paragraph~~.\n") == "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n" # GFM 492

# GFM: Autolinks (extension)
expect html("www.commonmark.org\n") == "<p><a href=\"http://www.commonmark.org\">www.commonmark.org</a></p>\n" # GFM 621
expect html("Visit www.commonmark.org/help for more information.\n") == "<p>Visit <a href=\"http://www.commonmark.org/help\">www.commonmark.org/help</a> for more information.</p>\n" # GFM 622
expect html("Visit www.commonmark.org.\n\nVisit www.commonmark.org/a.b.\n") == "<p>Visit <a href=\"http://www.commonmark.org\">www.commonmark.org</a>.</p>\n<p>Visit <a href=\"http://www.commonmark.org/a.b\">www.commonmark.org/a.b</a>.</p>\n" # GFM 623
expect html("www.google.com/search?q=Markup+(business)\n\nwww.google.com/search?q=Markup+(business)))\n\n(www.google.com/search?q=Markup+(business))\n\n(www.google.com/search?q=Markup+(business)\n") == "<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>))</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>)</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n" # GFM 624
expect html("www.google.com/search?q=(business))+ok\n") == "<p><a href=\"http://www.google.com/search?q=(business))+ok\">www.google.com/search?q=(business))+ok</a></p>\n" # GFM 625
expect html("www.google.com/search?q=commonmark&hl=en\n\nwww.google.com/search?q=commonmark&hl;\n") == "<p><a href=\"http://www.google.com/search?q=commonmark&amp;hl=en\">www.google.com/search?q=commonmark&amp;hl=en</a></p>\n<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&amp;hl;</p>\n" # GFM 626
expect html("www.commonmark.org/he<lp\n") == "<p><a href=\"http://www.commonmark.org/he\">www.commonmark.org/he</a>&lt;lp</p>\n" # GFM 627
expect html("http://commonmark.org\n\n(Visit https://encrypted.google.com/search?q=Markup+(business))\n\nAnonymous FTP is available at ftp://foo.bar.baz.\n") == "<p><a href=\"http://commonmark.org\">http://commonmark.org</a></p>\n<p>(Visit <a href=\"https://encrypted.google.com/search?q=Markup+(business)\">https://encrypted.google.com/search?q=Markup+(business)</a>)</p>\n<p>Anonymous FTP is available at <a href=\"ftp://foo.bar.baz\">ftp://foo.bar.baz</a>.</p>\n" # GFM 628
expect html("foo@bar.baz\n") == "<p><a href=\"mailto:foo@bar.baz\">foo@bar.baz</a></p>\n" # GFM 629
expect html("hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is.\n") == "<p>hello@mail+xyz.example isn't valid, but <a href=\"mailto:hello+xyz@mail.example\">hello+xyz@mail.example</a> is.</p>\n" # GFM 630
expect html("a.b-c_d@a.b\n\na.b-c_d@a.b.\n\na.b-c_d@a.b-\n\na.b-c_d@a.b_\n") == "<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a></p>\n<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a>.</p>\n<p>a.b-c_d@a.b-</p>\n<p>a.b-c_d@a.b_</p>\n" # GFM 631
