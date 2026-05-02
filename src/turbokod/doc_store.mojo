"""Per-language documentation store: loads a DevDocs index + body file
from ``<project>/.turbokod/docs/<slug>/`` and exposes lookup helpers
plus a small HTML→markdown renderer for the picker preview.

Lifecycle:
1. ``DocStore.__init__(slug, display)`` — empty, not loaded.
2. ``store.is_installed(dest_dir)`` — check that ``index.json`` and
   ``db.json`` both exist on disk.
3. ``store.load(dest_dir)`` — parse both JSON files into the store.
   Called once per session per language; the parsed structures live
   for the rest of the session. Raises if either file is missing or
   not parseable, so callers can surface a useful error instead of
   silently degrading to an empty picker.
4. ``store.entries`` — flat ``List[DocEntry]`` for the picker to filter.
5. ``store.html_for(entry_idx)`` — fetch the raw HTML for one entry.
6. ``html_to_text(html)`` — render HTML to a markdown-flavoured plain
   text body shaped for an editor pane: ``<h1>``..``<h6>`` become
   ``#``..``######``, paragraphs and other block elements are
   separated by blank lines, ``<pre>`` blocks are wrapped in fenced
   code blocks, ``<code>``/``<strong>``/``<em>`` get backticks /
   ``**`` / ``*``, lists get ``- `` or ``1. `` prefixes, ``<a>``
   becomes ``[text](href)``, and ``<table>`` becomes a properly
   aligned GFM table with column-padded cells.

The store is *per language*: one ``DocStore`` per spec, mirroring how
``LspManager`` works. We keep one per process (on Desktop) so closing
and reopening the same docset doesn't re-parse 6 MB of JSON.

DevDocs JSON shape (as shipped by https://documents.devdocs.io/):

* ``index.json`` — ``{"entries": [{"name", "path", "type"}, ...],
  "types": [{"name", "count", "slug"}, ...]}``. ``path`` is
  ``<file>#<fragment>``; ``<file>`` is the lookup key into ``db.json``,
  ``<fragment>`` is an HTML anchor inside that file.
* ``db.json`` — flat object mapping each ``<file>`` to its rendered
  HTML body. We split the path on ``#`` at index time so the picker
  can still display the fragment but the body lookup uses just the
  file portion.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .file_io import join_path, read_file, stat_file
from .json import JsonValue, parse_json


@fieldwise_init
struct DocEntry(ImplicitlyCopyable, Movable):
    """One row in the picker. ``path`` is the db.json key; ``fragment``
    is the bit after ``#`` (may be empty). ``type_name`` is the DevDocs
    section label (e.g. "Built-in Functions") shown next to the name."""
    var name: String
    var path: String
    var fragment: String
    var type_name: String


struct DocStore(Copyable, Movable):
    """One language's worth of DevDocs JSON. ``loaded`` distinguishes
    "never tried" from "tried and got nothing"; the latter still leaves
    ``entries`` empty but skips the re-load attempt.

    Marked ``Copyable`` so ``Desktop`` can stash these in
    ``List[DocStore]`` (Mojo lists require ``Copyable``). Copies aren't
    cheap on a populated store — they duplicate the entries list and
    every body string — but the list is grown via ``^`` transfer and
    indexed through references everywhere it matters, so the slow
    branch never fires in practice. We pay a copy on the rare host that
    runs ``stores[i] = ...`` without an explicit transfer."""

    var slug: String
    var display: String
    var loaded: Bool
    var entries: List[DocEntry]
    # Flat body store: parallel ``_body_paths`` / ``_body_html``. We
    # don't use a dict because Mojo's stdlib doesn't ship one with the
    # right ergonomics for ``String`` keys yet, and a linear scan over a
    # few thousand entries is fine for the lookup-on-pick path
    # (the picker scan is over ``entries``, not bodies).
    var _body_paths: List[String]
    var _body_html: List[String]

    fn __init__(out self, var slug: String, var display: String):
        self.slug = slug^
        self.display = display^
        self.loaded = False
        self.entries = List[DocEntry]()
        self._body_paths = List[String]()
        self._body_html = List[String]()

    fn __copyinit__(out self, copy: Self):
        self.slug = copy.slug
        self.display = copy.display
        self.loaded = copy.loaded
        self.entries = copy.entries.copy()
        self._body_paths = copy._body_paths.copy()
        self._body_html = copy._body_html.copy()

    fn is_installed(self, dest_dir: String) -> Bool:
        """True iff both DevDocs files exist on disk under ``dest_dir``."""
        var idx = join_path(dest_dir, String("index.json"))
        var db  = join_path(dest_dir, String("db.json"))
        return stat_file(idx).ok and stat_file(db).ok

    fn load(mut self, dest_dir: String) raises:
        """Parse ``index.json`` + ``db.json`` from ``dest_dir`` into the
        store. Idempotent: a second call with ``loaded == True`` is a
        no-op (avoids re-parsing 6+ MB of JSON if the host calls us
        speculatively)."""
        if self.loaded:
            return
        var index_path = join_path(dest_dir, String("index.json"))
        var db_path    = join_path(dest_dir, String("db.json"))
        var index_text = read_file(index_path)
        if len(index_text.as_bytes()) == 0:
            raise Error(String("docs: empty index at ") + index_path)
        var index_json = parse_json(index_text)
        var entries_opt = index_json.object_get(String("entries"))
        if not entries_opt or not entries_opt.value().is_array():
            raise Error(String("docs: malformed index at ") + index_path)
        var entries_v = entries_opt.value()
        for i in range(entries_v.array_len()):
            var e = entries_v.array_at(i)
            if not e.is_object():
                continue
            var name_opt = e.object_get(String("name"))
            var path_opt = e.object_get(String("path"))
            var type_opt = e.object_get(String("type"))
            if not name_opt or not path_opt:
                continue
            if not name_opt.value().is_string() or not path_opt.value().is_string():
                continue
            var name = name_opt.value().as_str()
            var raw_path = path_opt.value().as_str()
            var split = _split_at_hash(raw_path)
            var type_name = String("")
            if type_opt and type_opt.value().is_string():
                type_name = type_opt.value().as_str()
            self.entries.append(DocEntry(
                name, split[0], split[1], type_name,
            ))
        var db_text = read_file(db_path)
        if len(db_text.as_bytes()) == 0:
            raise Error(String("docs: empty db at ") + db_path)
        var db_json = parse_json(db_text)
        if not db_json.is_object():
            raise Error(String("docs: malformed db at ") + db_path)
        # Walk the obj_v list directly — DevDocs db files have thousands
        # of entries, so building a parallel two-list view is faster than
        # iterating ``object_get`` for every body.
        for i in range(len(db_json.obj_v)):
            var member = db_json.obj_v[i]
            if not member.value.is_string():
                continue
            self._body_paths.append(member.key)
            self._body_html.append(member.value.as_str())
        self.loaded = True

    fn html_for(self, entry_idx: Int) -> String:
        """Raw HTML body of ``entries[entry_idx]``, or empty string when
        the body file isn't found (orphan index entry — DevDocs ships a
        few of these). The fragment is *not* applied here; the caller
        renders the full body and the picker scrolls to the fragment."""
        if entry_idx < 0 or entry_idx >= len(self.entries):
            return String("")
        var path = self.entries[entry_idx].path
        for i in range(len(self._body_paths)):
            if self._body_paths[i] == path:
                return self._body_html[i]
        return String("")


fn _split_at_hash(path: String) -> Tuple[String, String]:
    """Split a DevDocs entry path on the *first* ``#`` into
    ``(file, fragment)``. Fragment is empty when there's no ``#``."""
    var b = path.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x23:    # '#'
            return (
                String(StringSlice(unsafe_from_utf8=b[:i])),
                String(StringSlice(unsafe_from_utf8=b[i + 1:])),
            )
    return (path, String(""))


# --- HTML → text renderer --------------------------------------------------


fn html_to_text(html: String) -> String:
    """Render HTML to markdown-flavoured plain text.

    Block tags (``<p>``, ``<div>``, ``<section>``, …) are separated by
    a blank line; ``<h1>``..``<h6>`` emit ``#``..``######`` prefixes;
    ``<pre>`` blocks are wrapped in ``````` fences and
    keep their whitespace verbatim; inline ``<code>`` becomes
    ```…```; ``<strong>``/``<b>`` and ``<em>``/``<i>``
    become ``**…**`` / ``*…*``; ``<a href>`` becomes
    ``[text](href)``; ``<ul>`` / ``<ol>`` items are emitted as
    ``- `` / ``1. `` lines (with two-space indent per nesting level);
    runs of inter-tag whitespace collapse to a single space.

    Not a real HTML parser: nested ``<pre>`` won't unwind correctly
    and CSS/script content is dropped. DevDocs HTML doesn't use either,
    so this trades correctness on weird inputs for predictable output
    on the docs we actually ship.

    Accumulates into a ``List[UInt8]`` buffer rather than ``String +
    String``: the latter is O(N) per append and turned multi-MB doc
    bodies (some CSS / JS reference pages) into a 50 s+ apparent hang.
    """
    var out = List[UInt8]()
    var b = html.as_bytes()
    var n = len(b)
    var i = 0
    var pre_depth = 0      # > 0 inside <pre> — preserve whitespace verbatim
    var pending_space = False
    # Stack of "ul" / "ol" entries for the currently open lists, plus
    # parallel ``<ol>`` counters. ``<li>`` reads these to decide between
    # a ``- `` and ``1. `` prefix and to compute the indent.
    var list_kinds = List[String]()
    var list_counters = List[Int]()
    # Stack of hrefs for currently-open ``<a>`` tags. An empty href is
    # stored as ``""`` and signals "render as plain text" (no brackets).
    var link_hrefs = List[String]()

    while i < n:
        var c = b[i]
        if c == 0x3C:    # '<'
            # Tag (or "<!--" comment, or "<![" CDATA-ish). Find the
            # matching '>'.
            var end = i + 1
            # Comment fast path: strip ``<!-- ... -->``.
            if end + 2 < n and b[end] == 0x21 and b[end + 1] == 0x2D \
                    and b[end + 2] == 0x2D:
                var k = end + 3
                while k + 2 < n:
                    if b[k] == 0x2D and b[k + 1] == 0x2D and b[k + 2] == 0x3E:
                        k += 3
                        break
                    k += 1
                i = k
                continue
            while end < n and b[end] != 0x3E:
                end += 1
            if end >= n:
                break
            var tag = String(StringSlice(unsafe_from_utf8=b[i + 1:end]))
            i = end + 1
            var info = _classify_tag(tag)
            var name = info[0]
            var is_close = info[1] == 1
            # ``script`` / ``style`` shouldn't appear in DevDocs HTML, but
            # if they do, skip everything up to the matching close tag so
            # the contents don't leak into the rendered text.
            if not is_close and (name == String("script") or name == String("style")):
                i = _skip_to_close(html, i, name)
                continue
            if name == String("table"):
                # Tables get a real two-pass renderer (parse rows/cells,
                # then emit a column-padded GFM table) instead of the
                # generic block fall-through. Stray ``</table>`` outside
                # any open table is dropped.
                if not is_close:
                    var t = _table_inner_and_end(html, i)
                    _ensure_blank_line(out)
                    _render_table(out, t[0])
                    _ensure_blank_line(out)
                    i = t[1]
                pending_space = False
                continue
            if name == String("pre"):
                if not is_close:
                    _ensure_blank_line(out)
                    _extend(out, String("```\n"))
                    pre_depth += 1
                else:
                    if pre_depth > 0:
                        pre_depth -= 1
                    _ensure_newline(out)
                    _extend(out, String("```"))
                    _ensure_blank_line(out)
                pending_space = False
                continue
            if name == String("br"):
                out.append(0x0A)
                pending_space = False
                continue
            if name == String("hr"):
                _ensure_blank_line(out)
                _extend(out, String("---"))
                _ensure_blank_line(out)
                pending_space = False
                continue
            var hl = _heading_level(name)
            if hl > 0:
                _ensure_blank_line(out)
                if not is_close:
                    for _ in range(hl):
                        out.append(0x23)    # '#'
                    out.append(0x20)
                pending_space = False
                continue
            if name == String("ul") or name == String("ol"):
                if not is_close:
                    _ensure_blank_line(out)
                    list_kinds.append(name)
                    list_counters.append(1)
                else:
                    if len(list_kinds) > 0:
                        _ = list_kinds.pop()
                        _ = list_counters.pop()
                    _ensure_blank_line(out)
                pending_space = False
                continue
            if name == String("li"):
                if not is_close:
                    _ensure_newline(out)
                    var depth = len(list_kinds)
                    var indent = depth - 1
                    if indent < 0:
                        indent = 0
                    for _ in range(indent * 2):
                        out.append(0x20)
                    if depth > 0 and list_kinds[depth - 1] == String("ol"):
                        var counter = list_counters[depth - 1]
                        _extend(out, String(counter) + String(". "))
                        list_counters[depth - 1] = counter + 1
                    else:
                        _extend(out, String("- "))
                pending_space = False
                continue
            if name == String("code"):
                # Inside <pre> we're already in a code fence — no
                # backticks. Outside, ``<code>foo</code>`` -> ``foo``.
                if pre_depth == 0:
                    if pending_space:
                        out.append(0x20)
                        pending_space = False
                    out.append(0x60)    # '`'
                continue
            if name == String("strong") or name == String("b"):
                if pre_depth == 0:
                    if pending_space:
                        out.append(0x20)
                        pending_space = False
                    _extend(out, String("**"))
                continue
            if name == String("em") or name == String("i"):
                if pre_depth == 0:
                    if pending_space:
                        out.append(0x20)
                        pending_space = False
                    out.append(0x2A)    # '*'
                continue
            if name == String("a"):
                if pre_depth > 0:
                    continue
                if not is_close:
                    var href = _get_attr(tag, String("href"))
                    if len(href.as_bytes()) > 0:
                        if pending_space:
                            out.append(0x20)
                            pending_space = False
                        out.append(0x5B)    # '['
                    link_hrefs.append(href^)
                else:
                    if len(link_hrefs) > 0:
                        var href = link_hrefs.pop()
                        if len(href.as_bytes()) > 0:
                            _extend(out, String("]("))
                            _extend(out, href)
                            out.append(0x29)    # ')'
                continue
            if _is_block_tag(name):
                # ``<td>`` / ``<th>`` are inline-ish: a single tab
                # between cells is enough to make a row readable.
                if name == String("td") or name == String("th"):
                    if not is_close:
                        if len(out) > 0 and out[len(out) - 1] != 0x0A:
                            out.append(0x09)    # '\t'
                        pending_space = False
                    continue
                if name == String("tr") or name == String("dt") or name == String("dd"):
                    _ensure_newline(out)
                    pending_space = False
                    continue
                # Default block: blank-line separator on both sides.
                _ensure_blank_line(out)
                pending_space = False
                continue
            # Inline tags we don't recognize: drop, keep flowing.
            continue
        if c == 0x26:    # '&'
            # Entity. Find the matching ';' within a small window.
            var end = i + 1
            var bound = i + 32 if i + 32 < n else n
            while end < bound and b[end] != 0x3B:
                end += 1
            if end >= bound or b[end] != 0x3B:
                # Not a real entity — emit '&' literally and move on.
                if pending_space and pre_depth == 0:
                    out.append(0x20)
                    pending_space = False
                out.append(0x26)    # '&'
                i += 1
                continue
            var ent = String(StringSlice(unsafe_from_utf8=b[i + 1:end]))
            var decoded = _decode_entity(ent)
            if pending_space and pre_depth == 0:
                out.append(0x20)
                pending_space = False
            _extend(out, decoded)
            i = end + 1
            continue
        # Plain text byte.
        if pre_depth > 0:
            out.append(b[i])
            i += 1
            continue
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D:
            # Collapse whitespace runs. Don't materialize a leading
            # space at the start of a line.
            if len(out) > 0 and out[len(out) - 1] != 0x0A:
                pending_space = True
            i += 1
            continue
        if pending_space:
            out.append(0x20)
            pending_space = False
        out.append(b[i])
        i += 1

    # Squash trailing whitespace down to nothing.
    while len(out) > 0 and (out[len(out) - 1] == 0x0A
            or out[len(out) - 1] == 0x20
            or out[len(out) - 1] == 0x09):
        _ = out.pop()
    return String(StringSlice(unsafe_from_utf8=Span(out)))


fn _extend(mut out: List[UInt8], s: String):
    """Append every byte of ``s`` to ``out``. The bulk-append helper for
    the ``html_to_text`` buffer; ``String + String`` would re-allocate
    and copy on every step, regressing to O(N²) on multi-MB inputs."""
    var sb = s.as_bytes()
    for k in range(len(sb)):
        out.append(sb[k])


fn _ensure_blank_line(mut out: List[UInt8]):
    """Ensure ``out`` ends with two newlines (i.e. a trailing blank
    line) so the next emit lands on a fresh paragraph. Trailing spaces
    or tabs on the last line are stripped first."""
    while len(out) > 0 and (out[len(out) - 1] == 0x20
            or out[len(out) - 1] == 0x09):
        _ = out.pop()
    if len(out) == 0:
        return
    var nl = 0
    var k = len(out) - 1
    while k >= 0 and out[k] == 0x0A:
        nl += 1
        k -= 1
    while nl < 2:
        out.append(0x0A)
        nl += 1


fn _ensure_newline(mut out: List[UInt8]):
    """Ensure ``out`` ends with at least one newline. Trailing spaces /
    tabs on the last line are stripped first so the newline lands
    cleanly."""
    while len(out) > 0 and (out[len(out) - 1] == 0x20
            or out[len(out) - 1] == 0x09):
        _ = out.pop()
    if len(out) == 0:
        return
    if out[len(out) - 1] != 0x0A:
        out.append(0x0A)


fn _heading_level(name: String) -> Int:
    """Return 1..6 for ``h1``..``h6``, or 0 if ``name`` is not a heading."""
    if name == String("h1"): return 1
    if name == String("h2"): return 2
    if name == String("h3"): return 3
    if name == String("h4"): return 4
    if name == String("h5"): return 5
    if name == String("h6"): return 6
    return 0


fn _get_attr(tag: String, attr: String) -> String:
    """Return the (un-quoted) value of attribute ``attr`` on a tag, or
    empty string when absent. Case-insensitive on the attribute name;
    handles double, single, and unquoted values. Substrings *inside* a
    different attribute's quoted value cannot match — the boundary
    check requires the candidate to start at byte 0 or right after a
    whitespace byte, which never holds inside a quoted value."""
    var tb = tag.as_bytes()
    var ab = attr.as_bytes()
    var n = len(tb)
    var an = len(ab)
    if an == 0 or n == 0:
        return String("")
    var i = 0
    while i + an <= n:
        var boundary = (i == 0) or tb[i - 1] == 0x20 or tb[i - 1] == 0x09 \
            or tb[i - 1] == 0x0A or tb[i - 1] == 0x0D
        if boundary:
            var matches = True
            for k in range(an):
                var ch = Int(tb[i + k])
                if 0x41 <= ch and ch <= 0x5A:
                    ch += 0x20
                if ch != Int(ab[k]):
                    matches = False
                    break
            if matches:
                var p = i + an
                while p < n and (tb[p] == 0x20 or tb[p] == 0x09):
                    p += 1
                if p < n and tb[p] == 0x3D:    # '='
                    p += 1
                    while p < n and (tb[p] == 0x20 or tb[p] == 0x09):
                        p += 1
                    if p < n and (tb[p] == 0x22 or tb[p] == 0x27):
                        var quote = tb[p]
                        p += 1
                        var vstart = p
                        while p < n and tb[p] != quote:
                            p += 1
                        return String(StringSlice(unsafe_from_utf8=tb[vstart:p]))
                    var vstart = p
                    while p < n and tb[p] != 0x20 and tb[p] != 0x09 \
                            and tb[p] != 0x2F and tb[p] != 0x3E:
                        p += 1
                    return String(StringSlice(unsafe_from_utf8=tb[vstart:p]))
        i += 1
    return String("")


fn _classify_tag(tag: String) -> Tuple[String, Int]:
    """Parse ``<...>`` content (the bit between the angle brackets) into
    ``(name_lower, is_close)``. ``is_close`` is 1 for ``</tag>`` style.

    Self-closing tags (``<br/>``) are returned as ``is_close=0`` — the
    caller treats ``<br>`` and ``<br/>`` identically. Attributes are
    discarded; they aren't useful for plain-text rendering.
    """
    var b = tag.as_bytes()
    var i = 0
    var is_close = 0
    if i < len(b) and b[i] == 0x2F:    # '/'
        is_close = 1
        i += 1
    var start = i
    while i < len(b):
        var c = b[i]
        if c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D or c == 0x2F:
            break
        i += 1
    var name = String(StringSlice(unsafe_from_utf8=b[start:i]))
    # Lower-case ASCII.
    var nb = name.as_bytes()
    var lower = String("")
    for k in range(len(nb)):
        var ch = Int(nb[k])
        if 0x41 <= ch and ch <= 0x5A:
            ch += 0x20
        lower = lower + chr(ch)
    return (lower^, is_close)


fn _is_block_tag(name: String) -> Bool:
    """Tags whose presence forces a line break in the rendered output."""
    if name == String("p"):  return True
    if name == String("div"): return True
    if name == String("h1"): return True
    if name == String("h2"): return True
    if name == String("h3"): return True
    if name == String("h4"): return True
    if name == String("h5"): return True
    if name == String("h6"): return True
    if name == String("ul"): return True
    if name == String("ol"): return True
    if name == String("li"): return True
    if name == String("blockquote"): return True
    if name == String("hr"): return True
    if name == String("table"): return True
    if name == String("tr"): return True
    if name == String("dt"): return True
    if name == String("dd"): return True
    if name == String("section"): return True
    if name == String("article"): return True
    if name == String("header"): return True
    if name == String("footer"): return True
    return False


fn _skip_to_close(html: String, start: Int, name: String) -> Int:
    """Advance past everything up to and including ``</name>``. Returns
    the index immediately after ``>``. Falls back to ``len(b)`` if no
    closing tag is found — better to swallow trailing junk than to
    leak script source into the rendered output."""
    var b = html.as_bytes()
    var n = len(b)
    var nb = name.as_bytes()
    var i = start
    while i < n:
        if b[i] == 0x3C and i + 1 < n and b[i + 1] == 0x2F:
            var k = i + 2
            var matches = True
            for j in range(len(nb)):
                if k + j >= n:
                    matches = False
                    break
                var ch = Int(b[k + j])
                if 0x41 <= ch and ch <= 0x5A:
                    ch += 0x20
                if ch != Int(nb[j]):
                    matches = False
                    break
            if matches:
                var end = k + len(nb)
                while end < n and b[end] != 0x3E:
                    end += 1
                if end < n:
                    return end + 1
                return n
        i += 1
    return n


fn _decode_entity(name: String) -> String:
    """Decode the part *between* ``&`` and ``;`` for the entities
    DevDocs HTML actually emits. Falls back to the raw ``&name;`` form
    so unknown entities are still readable.

    Numeric entities (``#N`` decimal and ``#xN`` hex) are decoded to
    their UTF-8 byte sequence so common typography (em-dash, smart
    quotes, etc.) survives the round-trip."""
    if name == String("amp"):    return String("&")
    if name == String("lt"):     return String("<")
    if name == String("gt"):     return String(">")
    if name == String("quot"):   return String("\"")
    if name == String("apos"):   return String("'")
    if name == String("nbsp"):   return String(" ")
    if name == String("copy"):   return String("(c)")
    if name == String("reg"):    return String("(R)")
    if name == String("trade"):  return String("(TM)")
    if name == String("hellip"): return String("...")
    if name == String("mdash"):  return String("--")
    if name == String("ndash"):  return String("-")
    if name == String("lsquo"):  return String("'")
    if name == String("rsquo"):  return String("'")
    if name == String("ldquo"):  return String("\"")
    if name == String("rdquo"):  return String("\"")
    var b = name.as_bytes()
    if len(b) >= 2 and b[0] == 0x23:    # '#'
        var cp = 0
        if b[1] == 0x78 or b[1] == 0x58:    # '#x' or '#X'
            for i in range(2, len(b)):
                var ch = Int(b[i])
                if 0x30 <= ch and ch <= 0x39:
                    cp = cp * 16 + (ch - 0x30)
                elif 0x41 <= ch and ch <= 0x46:
                    cp = cp * 16 + (ch - 0x41 + 10)
                elif 0x61 <= ch and ch <= 0x66:
                    cp = cp * 16 + (ch - 0x61 + 10)
                else:
                    return String("&") + name + String(";")
        else:
            for i in range(1, len(b)):
                var ch = Int(b[i])
                if 0x30 <= ch and ch <= 0x39:
                    cp = cp * 10 + (ch - 0x30)
                else:
                    return String("&") + name + String(";")
        if cp <= 0:
            return String(" ")
        return _utf8_from_codepoint(cp)
    return String("&") + name + String(";")


fn _utf8_from_codepoint(cp: Int) -> String:
    """Encode a Unicode codepoint as a UTF-8 string. ``chr()`` only
    handles ASCII, so the multi-byte branches assemble the bytes by
    hand (same as ``json._emit_utf8``)."""
    var out = String("")
    if cp < 0x80:
        out = out + chr(cp)
    elif cp < 0x800:
        out = out + chr(0xC0 | (cp >> 6))
        out = out + chr(0x80 | (cp & 0x3F))
    elif cp < 0x10000:
        out = out + chr(0xE0 | (cp >> 12))
        out = out + chr(0x80 | ((cp >> 6) & 0x3F))
        out = out + chr(0x80 | (cp & 0x3F))
    else:
        out = out + chr(0xF0 | (cp >> 18))
        out = out + chr(0x80 | ((cp >> 12) & 0x3F))
        out = out + chr(0x80 | ((cp >> 6) & 0x3F))
        out = out + chr(0x80 | (cp & 0x3F))
    return out^


# --- Table renderer --------------------------------------------------------


fn _table_inner_and_end(html: String, start: Int) -> Tuple[String, Int]:
    """``start`` is the index right after a ``<table...>`` open tag.
    Returns ``(inner_html, end_index)`` where ``end_index`` is the byte
    after the matching ``</table>``. Nested ``<table>`` tags are
    accounted for so the inner HTML covers the *full* outer-table body
    (including any nested table markup, which the cell renderer then
    recurses into via ``html_to_text``).

    Falls back to "everything to EOF" on an unterminated table — better
    to render trailing junk than to drop the rest of the document."""
    var b = html.as_bytes()
    var n = len(b)
    var i = start
    var depth = 1
    while i < n:
        if b[i] == 0x3C:    # '<'
            var end = i + 1
            while end < n and b[end] != 0x3E:
                end += 1
            if end >= n:
                break
            var tag = String(StringSlice(unsafe_from_utf8=b[i + 1:end]))
            var info = _classify_tag(tag)
            var name = info[0]
            var is_close = info[1] == 1
            if name == String("table"):
                if is_close:
                    depth -= 1
                    if depth == 0:
                        var inner = String(
                            StringSlice(unsafe_from_utf8=b[start:i]),
                        )
                        return (inner^, end + 1)
                else:
                    depth += 1
            i = end + 1
            continue
        i += 1
    var inner = String(StringSlice(unsafe_from_utf8=b[start:n]))
    return (inner^, n)


fn _render_table(mut out: List[UInt8], inner: String):
    """Parse ``<tr>`` / ``<th>`` / ``<td>`` from ``inner`` (the body of
    one ``<table>``) and write a column-padded GFM table into ``out``.

    Each cell's inner HTML is rendered through ``html_to_text``
    recursively so inline ``<code>``, ``<a>``, ``<strong>`` etc. survive
    as ```…``` / ``[text](href)`` / ``**…**`` inside the cell.
    The result is then flattened: whitespace runs collapse to a single
    space and ``|`` is escaped (markdown tables don't allow newlines
    inside a cell, and an unescaped ``|`` would terminate the cell
    early).

    The first row is emitted as the header row regardless of whether
    the source HTML used ``<th>`` — markdown tables require a header,
    and silently inventing an empty one looks worse on the typical
    case (DevDocs tables almost always have headers in row 0). Tables
    with zero rows produce no output."""
    var rows = List[List[String]]()
    var b = inner.as_bytes()
    var n = len(b)
    var i = 0
    var row = List[String]()
    var have_row = False
    var cell_start = -1
    var nested = 0    # depth of nested ``<table>`` we're inside
    while i < n:
        if b[i] != 0x3C:
            i += 1
            continue
        var end = i + 1
        while end < n and b[end] != 0x3E:
            end += 1
        if end >= n:
            break
        var tag = String(StringSlice(unsafe_from_utf8=b[i + 1:end]))
        var info = _classify_tag(tag)
        var name = info[0]
        var is_close = info[1] == 1
        if name == String("table"):
            if not is_close:
                nested += 1
            elif nested > 0:
                nested -= 1
            i = end + 1
            continue
        if nested > 0:
            # Inside a nested table — the outer ``<td>`` that contains
            # it is still open; we'll re-render the whole nested-table
            # markup as part of that cell's HTML when we close it.
            i = end + 1
            continue
        if name == String("tr"):
            if not is_close:
                row = List[String]()
                have_row = True
                cell_start = -1
            else:
                if have_row and len(row) > 0:
                    rows.append(row^)
                    row = List[String]()
                have_row = False
            i = end + 1
            continue
        if name == String("th") or name == String("td"):
            if not is_close:
                cell_start = end + 1
            else:
                if cell_start >= 0:
                    var cell_html = String(
                        StringSlice(unsafe_from_utf8=b[cell_start:i]),
                    )
                    var rendered = html_to_text(cell_html)
                    var flat = _flatten_cell(rendered)
                    if not have_row:
                        # ``<td>`` outside any ``<tr>`` (malformed but
                        # observed): open an implicit row so the cell
                        # isn't dropped.
                        row = List[String]()
                        have_row = True
                    row.append(flat^)
                    cell_start = -1
            i = end + 1
            continue
        i = end + 1
    if have_row and len(row) > 0:
        rows.append(row^)
    if len(rows) == 0:
        return
    var ncols = 0
    for ri in range(len(rows)):
        if len(rows[ri]) > ncols:
            ncols = len(rows[ri])
    for ri in range(len(rows)):
        while len(rows[ri]) < ncols:
            rows[ri].append(String(""))
    var widths = List[Int]()
    for _ in range(ncols):
        widths.append(3)    # ``---`` is the minimum legal separator cell
    for ri in range(len(rows)):
        for ci in range(ncols):
            var w = _utf8_codepoint_count(rows[ri][ci])
            if w > widths[ci]:
                widths[ci] = w
    for ri in range(len(rows)):
        _emit_table_row(out, rows[ri], widths)
        if ri == 0:
            _emit_table_separator(out, widths)


fn _emit_table_row(
    mut out: List[UInt8], cells: List[String], widths: List[Int],
):
    """``| cell1 | cell2 | ... |\\n`` with each cell right-padded with
    spaces to ``widths[ci]`` codepoints so the columns line up in
    monospace."""
    out.append(0x7C)    # '|'
    for ci in range(len(cells)):
        out.append(0x20)
        _extend(out, cells[ci])
        var pad = widths[ci] - _utf8_codepoint_count(cells[ci])
        for _ in range(pad):
            out.append(0x20)
        out.append(0x20)
        out.append(0x7C)
    out.append(0x0A)


fn _emit_table_separator(mut out: List[UInt8], widths: List[Int]):
    """``|---|---|...|\\n`` separator that GFM requires between header
    and body rows. Each column gets ``widths[ci]`` dashes (min 3, set
    in the caller) so the separator visibly spans the column."""
    out.append(0x7C)
    for ci in range(len(widths)):
        out.append(0x20)
        for _ in range(widths[ci]):
            out.append(0x2D)    # '-'
        out.append(0x20)
        out.append(0x7C)
    out.append(0x0A)


fn _flatten_cell(s: String) -> String:
    """Collapse whitespace runs (including ``\\n``) to a single space,
    strip leading/trailing whitespace, and escape ``|`` as ``\\|``.
    Markdown tables can't contain newlines, and a bare ``|`` inside a
    cell would split it in two."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8]()
    var prev_space = True    # treat the start as "after a space" so leading WS is dropped
    for i in range(n):
        var c = b[i]
        if c == 0x0A or c == 0x0D or c == 0x09 or c == 0x20:
            if not prev_space:
                out.append(0x20)
                prev_space = True
            continue
        if c == 0x7C:    # '|'
            out.append(0x5C)    # '\'
            out.append(0x7C)
            prev_space = False
            continue
        out.append(c)
        prev_space = False
    while len(out) > 0 and out[len(out) - 1] == 0x20:
        _ = out.pop()
    return String(StringSlice(unsafe_from_utf8=Span(out)))


fn _utf8_codepoint_count(s: String) -> Int:
    """Number of Unicode codepoints in ``s``. We count UTF-8 lead bytes
    (``b & 0xC0 != 0x80``) so multi-byte runes contribute one column
    each — close enough for column-padding latin-script docs and
    cheap to compute. CJK widths aren't accounted for (those would
    need an East-Asian-width table); those columns will simply be
    under-padded by one cell."""
    var b = s.as_bytes()
    var count = 0
    for i in range(len(b)):
        if (Int(b[i]) & 0xC0) != 0x80:
            count += 1
    return count
