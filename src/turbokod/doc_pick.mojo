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
from .quick_open import filter_indices_by_query
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
        self.matched = List[Int]()
        self.selected = 0
        self.selected_index = -1

    def open(
        mut self, var display: String, var entries: List[DocEntry],
    ):
        """Open the picker with ``entries`` already loaded."""
        self.display = display^
        self.entries = entries^
        # Precompute the ``type_name.name`` haystacks once so ``_refilter``
        # is a pure per-entry match with no string concatenation.
        self._haystacks = List[String]()
        for i in range(len(self.entries)):
            if len(self.entries[i].type_name.as_bytes()) > 0:
                self._haystacks.append(
                    self.entries[i].type_name + String(".")
                    + self.entries[i].name
                )
            else:
                self._haystacks.append(self.entries[i].name)
        self.query = TextField()
        self.active = True
        self.submitted = False
        self.matched = List[Int]()
        self.selected = 0
        self.selected_index = -1
        self._refilter()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.display = String("")
        self.query = TextField()
        self.entries = List[DocEntry]()
        self._haystacks = List[String]()
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
