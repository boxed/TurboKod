"""Project ▸ Spelling: every word the spell checker flags across the
project, most frequent first, with buttons to teach the dictionaries.

A declarative dialog (``ui`` / ``ui_set`` / ``ui_act``), so every look
draws it its own way and, where dialogs get windows (the Turbo Vision
look in the native app), it is a window of its own.

The dialog owns a ``ProjectSpellScan`` and advances it from ``tick``
(called once a frame by the host). Rows stream in while it runs and the
list re-sorts by count whenever they changed.

The list is a ``UI_MULTI`` list: a Shift range, or words picked one by
one with Cmd-click. Rows move whenever the list re-sorts, so the
selection is kept as word *keys* (and the caret and range anchor as the
words they're on), turned into row numbers for each frame's tree.
When the scan is done, a library check runs (the host drives it —
``Desktop._library_check_step``): each word not already ruled out is
looked up with the language server at up to three occurrences, and a word
defined in a library is learned (``Speller.add_library_word``) and drops
off the list. Both answers are remembered (``library_words.mojo``), so a
second run only asks about words it hasn't seen.

"Add to Project" / "Add to User" hand the selected words to the host
(``submitted`` + ``action``), which writes them to the dictionary and
calls ``acknowledge`` so the rows disappear.
"""

from std.collections.dict import Dict
from std.collections.list import List

from .file_io import project_relative
from std.collections.optional import Optional

from .library_words import LibraryNegatives
from .spell import Speller
from .spell_scan import ProjectSpellScan, SpellOccurrence, SpellScanWord
from .ui_tree import (
    ListWindow, UI_CANCEL, UI_DISABLED, UI_LARGE, UI_MULTI, UI_SECONDARY,
    UINode, ui_button, ui_buttons, ui_dialog, ui_int, ui_label, ui_list,
    ui_list_anchor, ui_list_row, ui_list_selected, ui_list_selection,
    ui_vstack,
)


comptime SPELLING_NONE = 0
comptime SPELLING_ADD_PROJECT = 1
comptime SPELLING_ADD_USER = 2

comptime _SCAN_BUDGET_MS = 40
"""Scan time spent per frame. The Swift host ticks every 50 ms (and the
terminal loops stop waiting on input while a scan runs — see
``Desktop.has_background_work``), so this leaves room for input and
paint while giving the scan most of the frame."""


@fieldwise_init
struct LibraryCheckJob(ImplicitlyCopyable, Movable):
    """One occurrence of a flagged word to look up."""
    var key: String
    var word: String
    var at: SpellOccurrence


struct SpellingDialog(Movable):
    var active: Bool
    var submitted: Bool
    """True when the user pressed one of the Add buttons. The host reads
    ``action`` and ``selected_keys()``, then calls ``acknowledge``."""
    var action: Int
    var scan: ProjectSpellScan
    var order: List[Int]
    """Rows on screen: indices into ``scan.words``, by count descending."""
    var _sorted_version: Int
    var _selected: Dict[String, Bool]
    """The selected words, by key."""
    var _caret: String
    var _anchor: String
    """The words the selection's moving and fixed ends are on."""
    var _selection: String
    """``_selected`` / ``_caret`` / ``_anchor`` as the list's value for the
    current ``order``; rebuilt when either changes."""
    var _selection_stale: Bool
    var window: ListWindow
    var has_project: Bool
    var root: String
    """The project root, for showing where a word was first seen."""
    var library_check: Bool
    """Run the library check after the scan (off in tests that only
    exercise the scan)."""
    var _lib_started: Bool
    var _lib_jobs: List[LibraryCheckJob]
    """Grouped by file, so consecutive lookups share an opened document."""
    var _lib_next: Int
    var _lib_left: Dict[String, Int]
    """Jobs not yet answered, per word."""
    var _lib_incomplete: Dict[String, Bool]
    """Words with an occurrence that couldn't be looked up (no server)."""
    var _lib_hit: Dict[String, Bool]
    var _lib_found: List[String]
    """Words learned as library names, dropped from the list next tick."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = SPELLING_NONE
        self.scan = ProjectSpellScan()
        self.order = List[Int]()
        self._sorted_version = -1
        self._selected = Dict[String, Bool]()
        self._caret = String("")
        self._anchor = String("")
        self._selection = String("")
        self._selection_stale = False
        self.window = ListWindow()
        self.has_project = False
        self.root = String("")
        self.library_check = True
        self._lib_started = False
        self._lib_jobs = List[LibraryCheckJob]()
        self._lib_next = 0
        self._lib_left = Dict[String, Int]()
        self._lib_incomplete = Dict[String, Bool]()
        self._lib_hit = Dict[String, Bool]()
        self._lib_found = List[String]()

    def open(
        mut self, var files: List[String], has_project: Bool,
        root: String = String(""),
    ):
        """Start a fresh scan of ``files`` and show the dialog."""
        self.active = True
        self.submitted = False
        self.action = SPELLING_NONE
        self.has_project = has_project
        self.root = root
        self.scan.start(files^)
        self._reset_library_check()
        self.order = List[Int]()
        self._sorted_version = -1
        self._clear_selection()
        self.window.reset()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = SPELLING_NONE
        self.scan.clear()
        self._reset_library_check()
        self.order = List[Int]()
        self._clear_selection()

    def tick(mut self, speller: Speller):
        """Advance the scan by one frame's budget and keep the list
        sorted. Called by the host every frame; free when closed."""
        if not self.active:
            return
        if self.scan.active:
            _ = self.scan.step(_SCAN_BUDGET_MS, speller)
        if len(self._lib_found) > 0:
            # ``order`` indexes the list ``remove_keys`` shrinks.
            self.order = List[Int]()
            self.scan.remove_keys(self._lib_found)
            self._lib_found = List[String]()
        if self._sorted_version != self.scan.version:
            self._resort()

    # --- library check ----------------------------------------------------

    def _reset_library_check(mut self):
        self._lib_started = False
        self._lib_jobs = List[LibraryCheckJob]()
        self._lib_next = 0
        self._lib_left = Dict[String, Int]()
        self._lib_incomplete = Dict[String, Bool]()
        self._lib_hit = Dict[String, Bool]()
        self._lib_found = List[String]()

    def library_check_due(self) -> Bool:
        """The scan just finished and the library check hasn't started."""
        return self.active and self.library_check and not self.scan.active \
            and not self._lib_started

    def start_library_check(mut self, negatives: LibraryNegatives):
        """Queue every occurrence kept for each word ``negatives`` hasn't
        ruled out, grouped by file."""
        self._reset_library_check()
        self._lib_started = True
        var by_path = Dict[String, List[Int]]()
        var paths = List[String]()
        var flat = List[LibraryCheckJob]()
        for i in range(len(self.scan.words)):
            ref w = self.scan.words[i]
            if negatives.contains(w.key):
                continue
            ref occ = self.scan.occurrences[i]
            self._lib_left[w.key] = len(occ)
            for k in range(len(occ)):
                var at = occ[k]
                if at.path not in by_path:
                    by_path[at.path] = List[Int]()
                    paths.append(at.path)
                try:
                    by_path[at.path].append(len(flat))
                except:
                    pass
                flat.append(LibraryCheckJob(w.key, w.word, at))
        for p in range(len(paths)):
            try:
                ref ids = by_path[paths[p]]
                for k in range(len(ids)):
                    self._lib_jobs.append(flat[ids[k]])
            except:
                pass

    def library_checking(self) -> Bool:
        """Lookups remain (the host may still have one in flight too)."""
        return self.active and self._lib_started \
            and self._lib_next < len(self._lib_jobs)

    def peek_library_job(mut self) -> Optional[LibraryCheckJob]:
        """The next lookup, skipping words already found to be library
        names; None when there are no more."""
        while self._lib_next < len(self._lib_jobs):
            var job = self._lib_jobs[self._lib_next]
            if job.key in self._lib_hit:
                self._lib_next += 1
                continue
            return Optional[LibraryCheckJob](job)
        return Optional[LibraryCheckJob]()

    def pop_library_job(mut self):
        if self._lib_next < len(self._lib_jobs):
            self._lib_next += 1

    def library_result(mut self, key: String, hit: Bool) -> Bool:
        """Record an answer for ``key``. True when that was the word's
        last occurrence, every one was looked up, and none was a
        library's — the host remembers it as ruled out."""
        if hit:
            if key not in self._lib_hit:
                self._lib_hit[key] = True
                self._lib_found.append(key)
            return False
        return self._answered(key)

    def library_skip(mut self, key: String):
        """An occurrence of ``key`` that couldn't be looked up."""
        self._lib_incomplete[key] = True
        _ = self._answered(key)

    def _answered(mut self, key: String) -> Bool:
        var left = self._lib_left.get(key, 0) - 1
        self._lib_left[key] = left
        return left == 0 and key not in self._lib_hit \
            and key not in self._lib_incomplete

    # --- results ----------------------------------------------------------

    def selected_keys(self) -> List[String]:
        """Selected words in list order — what an Add button applies to."""
        var out = List[String]()
        for i in range(len(self.order)):
            var key = self._key_at(i)
            if key in self._selected:
                out.append(key^)
        return out^

    def acknowledge(mut self, added: List[String]):
        """The host handled an Add: drop those rows and clear the
        selection."""
        self.submitted = False
        self.action = SPELLING_NONE
        # ``order`` indexes the word list ``remove_keys`` is about to
        # shrink, so drop it before anything reads it again.
        self.order = List[Int]()
        self.scan.remove_keys(added)
        self._clear_selection()
        self._resort()

    # --- sorting + selection ----------------------------------------------

    def _resort(mut self):
        """Rebuild ``order``: count descending, then word."""
        var idx = List[Int](capacity=len(self.scan.words))
        for i in range(len(self.scan.words)):
            idx.append(i)
        _merge_sort(idx, self.scan.words)
        self.order = idx^
        self._sorted_version = self.scan.version
        self._selection_stale = True

    def _clear_selection(mut self):
        self._selected = Dict[String, Bool]()
        self._caret = String("")
        self._anchor = String("")
        self._selection = String("")
        self._selection_stale = False

    def _selection_value(mut self) -> String:
        """The list's value for the current rows (``ui_list_selection``)."""
        if not self._selection_stale:
            return self._selection
        self._selection_stale = False
        if len(self._selected) == 0:
            self._selection = String("")
            return self._selection
        var rows = List[Int]()
        var caret = -1
        var anchor = -1
        for i in range(len(self.order)):
            var key = self._key_at(i)
            if key in self._selected:
                rows.append(i)
            if key == self._caret:
                caret = i
            if key == self._anchor:
                anchor = i
        if caret < 0 and len(rows) > 0:
            caret = rows[0]
        self._selection = ui_list_selection(anchor, caret, rows)
        return self._selection

    def _select(mut self, value: String):
        """The projector's selection value, as words."""
        self._selected = Dict[String, Bool]()
        self._caret = String("")
        self._anchor = String("")
        var n = len(self.order)
        var rows = ui_list_selected(value)
        for i in range(len(rows)):
            if rows[i] < n:
                self._selected[self._key_at(rows[i])] = True
        var row = ui_list_row(value)
        var anchor = ui_list_anchor(value)
        if 0 <= row and row < n:
            self._caret = self._key_at(row)
        if 0 <= anchor and anchor < n:
            self._anchor = self._key_at(anchor)
        self._selection = value
        self._selection_stale = False

    # --- the dialog -------------------------------------------------------

    def ui(mut self) -> UINode:
        var n = len(self.order)
        var status: String
        if self.library_checking():
            status = String("Checking for library names ") \
                + String(self._lib_next) + String(" / ") \
                + String(len(self._lib_jobs)) + String("…")
        elif self.scan.active:
            status = String("Scanning ") + String(self.scan.files_done) \
                + String(" / ") + String(len(self.scan.files)) \
                + String(" files… ") \
                + String(Int(self.scan.progress() * 100)) + String("%")
        else:
            status = String(self.scan.files_checked) \
                + String(" files checked, ") + String(len(self.scan.words)) \
                + String(" suspect words")
        var selection = self._selection_value()
        var bounds = self.window.range(n, ui_list_row(selection))
        var rows = List[List[String]]()
        for i in range(bounds[0], bounds[1]):
            ref w = self.scan.words[self.order[i]]
            var r = List[String]()
            r.append(w.word)
            # How often, then where it was first seen.
            r.append(
                String(w.count) + String("×  ")
                + project_relative(self.root, w.path) + String(":")
                + String(w.line),
            )
            rows.append(r^)
        var n_selected = len(self._selected)
        var note: String
        if n == 0:
            note = String("Looking for misspellings…") if self.scan.active \
                else String("No misspellings found.")
        else:
            note = String(n_selected) + String(" selected")
        var body = List[UINode]()
        body.append(ui_label(status^))
        body.append(ui_list(
            String("words"), n, bounds[0], rows^, selection, String(""), 16,
            UI_MULTI,
        ))
        body.append(ui_label(note^, UI_SECONDARY))
        var buttons = List[UINode]()
        buttons.append(ui_button(String("close"), String("Close"), UI_CANCEL))
        buttons.append(ui_button(
            String("user"), String("Add to User"),
            0 if n_selected > 0 else UI_DISABLED,
        ))
        buttons.append(ui_button(
            String("project"), String("Add to Project"),
            0 if n_selected > 0 and self.has_project else UI_DISABLED,
        ))
        body.append(ui_buttons(buttons^))
        # Large: most of the window, and resizable, like the pickers.
        var d = ui_dialog(String("Spelling"), String("close"), ui_vstack(body^))
        d.flags |= UI_LARGE
        return d^

    def ui_set(mut self, key: String, value: String):
        if key == String("words"):
            self._select(value)
        elif key == String("words@top"):
            self.window.view_at(ui_int(value, 0))

    def ui_act(mut self, id: String):
        if id == String("close"):
            self.close()
        elif id == String("project"):
            self._submit(SPELLING_ADD_PROJECT)
        elif id == String("user"):
            self._submit(SPELLING_ADD_USER)

    def _submit(mut self, action: Int):
        if len(self._selected) == 0:
            return
        if action == SPELLING_ADD_PROJECT and not self.has_project:
            return
        self.action = action
        self.submitted = True

    def _key_at(self, i: Int) -> String:
        return self.scan.words[self.order[i]].key


def _before(a: SpellScanWord, b: SpellScanWord) -> Bool:
    """List order: higher count first, then the word alphabetically."""
    if a.count != b.count:
        return a.count > b.count
    return a.key < b.key


def _merge_sort(mut idx: List[Int], words: List[SpellScanWord]):
    """Stable sort of ``idx`` (indices into ``words``) by ``_before``.
    Merge sort rather than insertion: a project yields thousands of
    distinct words and the list re-sorts while the scan runs."""
    var n = len(idx)
    if n < 2:
        return
    var buf = List[Int](capacity=n)
    for i in range(n):
        buf.append(idx[i])
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if _before(words[idx[j]], words[idx[i]]):
                    buf[k] = idx[j]
                    j += 1
                else:
                    buf[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                buf[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                buf[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for t in range(n):
            idx[t] = buf[t]
        width *= 2
