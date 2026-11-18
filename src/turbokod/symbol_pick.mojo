"""SymbolPick: type-to-filter list of LSP document symbols.

A modal centered dialog, like ``QuickOpen``, but populated from a
``textDocument/documentSymbol`` response instead of the project file
walk. The Desktop opens the picker (in a "loading…" state), kicks off
the LSP request, and feeds the result list in via ``set_entries`` once
``LspManager.take_symbols`` returns. Selection submits ``(line, character)``
which the host uses to move the cursor.

The match algorithm is borrowed from ``quick_open_match`` so users get
the same fuzzy-with-word-boundary feel they're already used to.
"""

from std.collections.list import List

from .lsp_dispatch import SymbolItem
from .quick_open import filter_indices_by_query
from .text_field import TextField


struct SymbolPick(Movable):
    var active: Bool
    var loading: Bool       # True while waiting for the LSP response
    var submitted: Bool
    var path: String        # the file the symbols belong to
    var query: TextField
    var entries: List[SymbolItem]
    # Precomputed ``container.name`` (or bare ``name``) match haystacks,
    # parallel to ``entries`` — built once in ``set_entries`` so
    # ``_refilter`` doesn't reconcatenate per entry on every keystroke.
    var _haystacks: List[String]
    var matched: List[Int]
    var selected: Int
    # Submission output — read after ``submitted`` flips True.
    var selected_line: Int
    var selected_character: Int

    def __init__(out self):
        self.active = False
        self.loading = False
        self.submitted = False
        self.path = String("")
        self.query = TextField()
        self.entries = List[SymbolItem]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.selected_line = 0
        self.selected_character = 0

    def open(mut self, var path: String):
        """Open the picker in a loading state for ``path``. Entries arrive
        later via ``set_entries`` once the LSP responds."""
        self.path = path^
        self.query = TextField()
        self.active = True
        self.loading = True
        self.submitted = False
        self.entries = List[SymbolItem]()
        self._haystacks = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.selected_line = 0
        self.selected_character = 0

    def set_entries(mut self, var items: List[SymbolItem]):
        """Populate the picker with the response and clear the loading flag.
        Refilters with the current query in case the user typed while we
        were waiting."""
        self.entries = items^
        # Precompute the ``container.name`` haystacks once so ``_refilter``
        # is a pure per-entry match with no string concatenation.
        self._haystacks = List[String]()
        for i in range(len(self.entries)):
            if len(self.entries[i].container.as_bytes()) > 0:
                self._haystacks.append(
                    self.entries[i].container + String(".")
                    + self.entries[i].name
                )
            else:
                self._haystacks.append(self.entries[i].name)
        self.loading = False
        self._refilter()

    def close(mut self):
        self = SymbolPick()

    # --- filtering --------------------------------------------------------

    def set_query(mut self, var text: String):
        """The native search field's text (macOS-style UI)."""
        if text == self.query.text:
            return
        self.query.set_text(text^)
        self._refilter()

    def _refilter(mut self):
        # Match against the precomputed ``container.name`` haystacks
        # (parallel to ``entries``, built in ``set_entries``) so users can
        # type a parent-class prefix to narrow nested methods.
        self.matched = filter_indices_by_query(self._haystacks, self.query.text)
        self.selected = 0

    def submit(mut self):
        """Jump to the selected symbol: sets ``selected_line`` /
        ``selected_character`` and flips ``submitted``."""
        if not self.active \
                or self.selected < 0 or self.selected >= len(self.matched):
            return
        var sym = self.entries[self.matched[self.selected]]
        self.selected_line = sym.line
        self.selected_character = sym.character
        self.submitted = True


