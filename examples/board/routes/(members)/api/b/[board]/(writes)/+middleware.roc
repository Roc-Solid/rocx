import ../../../../../../Middlewares

## A board's changes (its cards, columns and moves; not a card's edit lease, which a page renews
## while it is open): at most 60 at once for each person, then one a second.
middleware = Middlewares.writes
