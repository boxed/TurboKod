"""Repro: spawning a child process via ``posix_spawnp`` corrupts the
parent's subsequent ``read()`` from a raw-mode TTY. Pre-spawn TTY
reads work fine; the very first post-spawn TTY read segfaults.

Run interactively:

    pixi run mojo run -I src tests/spawn_then_read_repro.mojo

Phases:

1. Set raw mode on stdin.
2. Read 3 times from the TTY (press 3 keys). Each should print
   ``pre-spawn read N=<n>``.
3. ``posix_spawnp`` a trivial ``/bin/true``. Wait for it.
4. Read once from the TTY (press 1 key). This is expected to
   segfault — the bug.

If step 4 succeeds and prints ``post-spawn read N=<n>`` then the
hypothesis is wrong and the bug lives elsewhere.
"""

from std.collections.list import List
from std.ffi import external_call

from turbokod.posix import (
    POSIX_SPAWN_FILE_ACTIONS_SIZE, STDIN_FD, TCSANOW, TERMIOS_SIZE,
    alloc_zero_buffer, cfmakeraw, poll_stdin,
    posix_spawn_file_actions_destroy, posix_spawn_file_actions_init,
    posix_spawnp_call, tcgetattr, tcsetattr, waitpid_blocking,
)


fn _read_one_keypress(label: String) raises:
    print(label, "— press a key")
    while not poll_stdin(STDIN_FD, Int32(1000)):
        pass
    var buf = alloc_zero_buffer(64)
    var n = external_call["read", Int](STDIN_FD, buf.unsafe_ptr(), 64)
    print(label, " -> N=", n)


fn main() raises:
    var orig = alloc_zero_buffer(TERMIOS_SIZE)
    if tcgetattr(STDIN_FD, orig) != 0:
        print("not a tty"); return
    var raw = alloc_zero_buffer(TERMIOS_SIZE)
    for i in range(TERMIOS_SIZE):
        raw[i] = orig[i]
    cfmakeraw(raw)
    _ = tcsetattr(STDIN_FD, TCSANOW, raw)
    try:
        # ---- Phase 1: pre-spawn reads ----
        for i in range(3):
            _read_one_keypress(String("pre-spawn ") + String(i + 1))
        # ---- Phase 2: spawn a trivial child ----
        print("about to posix_spawnp /bin/true")
        var argv = List[String]()
        argv.append(String("/bin/true"))
        # Build argv pointer array.
        var argv_blob = List[UInt8]()
        var argv_offsets = List[Int]()
        for k in range(len(argv)):
            argv_offsets.append(len(argv_blob))
            var b = argv[k].as_bytes()
            for q in range(len(b)):
                argv_blob.append(b[q])
            argv_blob.append(0)
        var nptr = len(argv) + 1
        var argv_ptrs = alloc_zero_buffer(nptr * 8)
        var pp = argv_ptrs.unsafe_ptr().bitcast[Int]()
        for k in range(len(argv)):
            pp[k] = Int(argv_blob.unsafe_ptr()) + argv_offsets[k]
        pp[len(argv)] = 0
        # Empty envp.
        var envp_ptrs = alloc_zero_buffer(8)
        envp_ptrs.unsafe_ptr().bitcast[Int]()[0] = 0
        var fa = alloc_zero_buffer(POSIX_SPAWN_FILE_ACTIONS_SIZE)
        _ = posix_spawn_file_actions_init(fa)
        var pid = posix_spawnp_call(argv_ptrs, envp_ptrs, fa, argv[0])
        _ = posix_spawn_file_actions_destroy(fa)
        _ = waitpid_blocking(pid)
        print("spawn complete pid=", Int(pid))
        # ---- Phase 3: post-spawn read ----
        _read_one_keypress(String("post-spawn"))
        print("post-spawn read survived; hypothesis wrong")
    finally:
        _ = tcsetattr(STDIN_FD, TCSANOW, orig)
