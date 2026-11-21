function Friends() {
  const [shown, setShown] = createSignal(3);
  const friends = createMemo(() => getFriends());
  return (
    <Loading fallback={<p>Loading…</p>}>
      <ul>
        <For each={friends().slice(0, shown())} keyed={(f) => f.id}>
          {(friend) => <li>{friend().name}</li>}
        </For>
      </ul>
      <Show when={friends().length > shown()}>
        <button onClick={() => setShown(shown() + 3)}>More</button>
      </Show>
    </Loading>
  );
}
