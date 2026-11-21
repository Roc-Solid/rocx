// The guard around every call into Roc. Roc's ABI says `roc_crashed` must never return: it ends
// the process, or longjmps out of the Roc code that called it. The host does the second, so a
// crash (`crash`, an integer overflowing) ends one request, not the server.
//
// `rocx_guarded` calls `call(data)` with a jump target set; `rocx_guard_escape`, called by
// `roc_crashed`, jumps back to it, and `rocx_guarded` returns 1. The frames it skips are Roc's,
// and the host's trampoline, which holds nothing to drop; hosted functions never call back into
// Roc, so a crash never skips one of theirs.
#include <setjmp.h>
#include <stddef.h>

static _Thread_local jmp_buf *current = NULL;

int rocx_guarded(void (*call)(void *), void *data) {
    jmp_buf here;
    jmp_buf *volatile outer = current;
    current = &here;
    if (setjmp(here) != 0) {
        current = outer;
        return 1;
    }
    call(data);
    current = outer;
    return 0;
}

int rocx_guard_active(void) {
    return current != NULL;
}

void rocx_guard_escape(void) {
    longjmp(*current, 1);
}
