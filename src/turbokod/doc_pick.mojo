"""DocPick: type-to-filter list of documentation entries.

A modal centered dialog (same shape as ``SymbolPick`` and ``QuickOpen``)
populated from a ``DocStore``'s ``entries``. The Desktop opens the
picker after ensuring docs are installed and loaded; selecting an
entry submits ``selected_index``, which the host uses to open the
rendered HTML body in a read-only editor pane.

The match algorithm is borrowed from ``quick_open_match`` so users get
the same fuzzy-with-word-boundary feel as Quick Open / Go to Symbol.
"""

from std.collections.list import List

from .doc_store import DocEntry
from .quick_open import filter_indices_by_query, qualified_name
from .text_field import TextField


struct DocPick(Movable):
    var active: Bool
    var submitted: Bool
    var display: String          # docset name shown in title ("Python 3.12")
    var query: TextField
    var entries: List[DocEntry]
    # Precomputed ``type_name.name`` (or bare ``name``) match haystacks,
    # parallel to ``entries`` — built once in ``open`` so ``_refilter``
    # doesn't reconcatenate per entry on every keystroke.
    var _haystacks: List[String]
    # The docset ``entries`` / ``_haystacks`` were built for, kept across
    # ``close`` so a reopen can skip rebuilding them (see ``open``).
    var _cached_display: String
    var matched: List[Int]
    var selected: Int
    # Submission output — index into ``entries`` (not ``matched``), set
    # before ``submitted`` flips True so the host doesn't have to keep
    # the picker alive after consuming.
    var selected_index: Int

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self._haystacks = List[String]()
        self._cached_display = String("")
        self.matched = List[Int]()
        self.selected = 0
        self.selected_index = -1

    def open(
        mut self, var display: String, entries: List[DocEntry],
    ):
        """Open the picker over ``entries`` (a ``DocStore``'s, borrowed).

        A docset holds thousands of entries, so they and their match
        haystacks are kept after ``close``: reopening the same docset
        (``display``, same entry count) reuses them instead of copying
        the list and rebuilding a haystack per entry on every Ctrl+K."""
        if not self._holds(display, entries):
            self.entries = entries.copy()
            # Precompute the ``type_name.name`` haystacks once so
            # ``_refilter`` is a pure per-entry match with no string
            # concatenation.
            self._haystacks = List[String](capacity=len(self.entries))
            for i in range(len(self.entries)):
                self._haystacks.append(qualified_name(
                    self.entries[i].type_name, self.entries[i].name,
                ))
            self._cached_display = display
        self.display = display^
        self.query = TextField()
        self.active = True
        self.submitted = False
        self.matched = List[Int]()
        self.selected = 0
        self.selected_index = -1
        self._refilter()

    def _holds(self, display: String, entries: List[DocEntry]) -> Bool:
        """Whether the kept ``entries`` are ``display``'s ``entries``: same
        docset, count and ends (a reinstall that changed the list changes
        one of them)."""
        var n = len(entries)
        if display != self._cached_display or n != len(self.entries):
            return False
        if n == 0:
            return True
        return entries[0].path == self.entries[0].path \
            and entries[n - 1].path == self.entries[n - 1].path \
            and entries[n - 1].name == self.entries[n - 1].name

    def close(mut self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        # ``entries`` / ``_haystacks`` stay for the next ``open`` of the
        # same docset.
        self.matched = List[Int]()
        self.selected = 0
        self.selected_index = -1

    # --- filtering --------------------------------------------------------

    def set_query(mut self, var text: String):
        """The native search field's text (macOS-style UI)."""
        if text == self.query.text:
            return
        self.query.set_text(text^)
        self._refilter()

    def _refilter(mut self):
        # Match against the precomputed ``type.name`` haystacks (parallel to
        # ``entries``, built in ``open``) so the user can type a section
        # prefix (e.g. ``stdt`` for ``str.find`` under "Standard Types") to
        # narrow nested entries.
        self.matched = filter_indices_by_query(self._haystacks, self.query.text)
        self.selected = 0

    def submit(mut self):
        """Open the selected entry: sets ``selected_index`` and flips
        ``submitted``."""
        if not self.active \
                or self.selected < 0 or self.selected >= len(self.matched):
            return
        self.selected_index = self.matched[self.selected]
        self.submitted = True
