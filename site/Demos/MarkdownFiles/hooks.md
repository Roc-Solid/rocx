### Counting what you see

A counter is a signal and a button:

```roc
(count!, set_count!) = create_signal!(0)
<button on:click={|| set_count!(count!() + 1)}>{count!().to_str()}</button>
```

The `.rocx` file it is in is plain Roc around the markup. More on
[roc-lang.org](https://www.roc-lang.org).
