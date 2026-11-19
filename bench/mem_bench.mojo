"""What does one open buffer keep alive, step by step?

Footprint can't answer that: the Mojo runtime's allocator (a bundled
tcmalloc) keeps freed memory in a pool of several megabytes, so a short
run's new allocations land in it and the process doesn't grow. Its
statistics can, and it prints them at exit when ``MALLOCSTATS=1`` is set —
"Bytes in use by application" is the exact live total. So this runs to a
chosen stop point and exits there with everything still referenced; the
difference between two stop points is what the step in between kept.

    ./run.sh bench/mem_bench.mojo <file> 99      # build; 99 runs to the end
    for i in 0 1 2 3 4 5 6; do
      MALLOCSTATS=1 DYLD_LIBRARY_PATH=.pixi/envs/default/lib \\
        .build/mem_bench_* <file> $i 2>&1 | grep 'in use by application'
    done

Stop points: 0 a first editor on the file fully set up (grammar compiled,
dictionary loaded), then for a second editor on it: 1 ``Editor.from_file``,
2 ``sync_highlights``, 3 ``_index_highlights``, 4 ``_refresh_spell``,
5 ``set_git_head_text``, 6 ``lsp_text``. Run it with a scratch ``HOME``:
the dictionary load reads the user's installed dictionaries.

It counts the Mojo heap only. libonig's compiled regexes are on the system
heap; ``heap <pid>`` / ``vmmap -summary <pid>`` on the running app show
those (see docs/memory.md).
"""

from std.ffi import external_call
from std.sys import argv

from turbokod.editor import Editor
from turbokod.file_io import read_file
from turbokod.highlight import GrammarRegistry, extension_of, sync_highlights
from turbokod.spell import Speller
from turbokod.string_utils import parse_int_all


def _stop_here(n: Int, stop: Int):
    """Exit now, without running any destructor, if this is the stop
    point asked for."""
    if n == stop:
        external_call["exit", NoneType](Int32(0))


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: mem_bench <file> <stop point 0-6>")
        return
    var path = String(args[1])
    var stop = parse_int_all(String(args[2]))
    var registry = GrammarRegistry()
    var speller = Speller()
    speller.load_default()
    var warm = Editor.from_file(path)
    warm.flush_highlights(registry, speller)
    var text = read_file(path)
    _stop_here(0, stop)
    var ed = Editor.from_file(path)
    _stop_here(1, stop)
    sync_highlights(
        extension_of(ed.file_path), ed.buffer.lines, 0,
        registry, ed._hl_cache, ed.highlights, -1,
    )
    _stop_here(2, stop)
    ed._index_highlights()
    _stop_here(3, stop)
    ed._refresh_spell(speller)
    _stop_here(4, stop)
    ed.set_git_head_text(text, True)
    _stop_here(5, stop)
    _ = ed.lsp_text()
    _stop_here(6, stop)
    # Everything above stays referenced to here, so nothing is destroyed
    # before a stop point: values are otherwise freed at their last use.
    print(
        len(ed.highlights), len(warm.highlights), text.byte_length(),
        speller.is_loaded(), len(registry.overrides),
    )
    registry.release()
