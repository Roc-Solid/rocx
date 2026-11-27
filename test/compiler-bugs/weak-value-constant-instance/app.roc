app [main] { pf: platform "platform/main.roc" }

# A polymorphic constant: the type of its items generalizes.
empty = []

# A platform requirement types `main`, so `main` is a weak value, never
# generalized. Its Model, `{ seen : List(a) }`, keeps an item type
# nothing fixes, and `init` reads `empty` at it.
main = {
    init: |{}| { seen: empty },
    read: |model| model.seen.len(),
}
