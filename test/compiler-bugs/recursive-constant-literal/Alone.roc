# The same constants, each in a binding group of its own: every use shares
# the literal's one weak type. Passes on every compiler; the recursive group
# should not change that.

holder = { n: 1, run: |input| input }

counted = { n: 3, run: |input| input * 2 }

expect (holder.run)(1.U64) == 1
expect holder.n == 1
expect (counted.run)(3.U64) == 6
expect counted.n + 1.U8 == 4
