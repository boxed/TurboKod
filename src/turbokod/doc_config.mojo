"""DevDocs-style offline documentation registry, modeled on ``language_config``.

A built-in catalog of documentation sets keyed by language id, mirroring
the LSP registry's shape: each entry binds a language id and its file
extensions to a *DevDocs slug* (the directory name DevDocs uses for the
docset, e.g. ``python~3.12`` or ``rust``) and a one-line install hint
that fetches both ``index.json`` and ``db.json`` into
``<project>/.turbokod/docs/<slug>/``.

The fetch is driven by ``InstallRunner`` — same single-slot subprocess
wrapper the LSP install path uses — so users get the same "Install <X>?"
prompt and the same non-modal progress popup.

Why DevDocs:
* Their JSON dumps are CC-BY/MIT-licensed and small (a few MB per docset),
  so we can ship doc lookup that works completely offline once fetched.
* Each slug ships ``index.json`` (a flat list of named entries with
  ``path`` + ``type``) and ``db.json`` (a path → HTML-blob map). The
  index is what powers our fuzzy picker; ``db.json`` is the body store
  we render on demand.
"""

from std.collections.list import List


comptime DEVDOCS_BASE = String("https://documents.devdocs.io/")


struct DocSpec(ImplicitlyCopyable, Movable):
    """Routing entry: which file extensions belong to this language id,
    plus the DevDocs slug to fetch when the user asks for docs.

    ``slug`` is the DevDocs directory name (``python~3.12`` etc.) — that
    string is what gets appended to ``DEVDOCS_BASE`` to download the
    JSON files, and it's also the on-disk directory name under
    ``.turbokod/docs/``. ``display`` is the human-readable label
    (``Python 3.12``) we show in prompts and the picker title.
    """
    var language_id: String
    var file_types: List[String]
    var slug: String
    var display: String

    fn __init__(
        out self, var language_id: String,
        var file_types: List[String],
        var slug: String,
        var display: String,
    ):
        self.language_id = language_id^
        self.file_types = file_types^
        self.slug = slug^
        self.display = display^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.file_types = copy.file_types.copy()
        self.slug = copy.slug
        self.display = copy.display


fn _exts(*items: String) -> List[String]:
    var out = List[String]()
    for x in items:
        out.append(String(x))
    return out^


fn built_in_docsets() -> List[DocSpec]:
    """Curated set of DevDocs slugs matching the languages we already
    grammar-highlight or run an LSP for.

    Slug versions are pinned (e.g. ``python~3.12``) so a tutorial that
    Just Works today doesn't silently change content under the user
    later. Bumping a version is a one-line edit here; the fetch helper
    will see a different slug and treat it as a fresh install.
    """
    var out = List[DocSpec]()

    out.append(DocSpec(
        String("python"),
        _exts(String("py"), String("pyi"), String("pyw")),
        String("python~3.12"), String("Python 3.12"),
    ))
    out.append(DocSpec(
        String("rust"),
        _exts(String("rs")),
        String("rust"), String("Rust"),
    ))
    out.append(DocSpec(
        String("go"),
        _exts(String("go")),
        String("go"), String("Go"),
    ))
    out.append(DocSpec(
        String("typescript"),
        _exts(
            String("ts"), String("tsx"), String("js"), String("jsx"),
            String("mjs"), String("cjs"),
        ),
        String("typescript"), String("TypeScript"),
    ))
    out.append(DocSpec(
        String("cpp"),
        _exts(
            String("c"), String("h"), String("cc"), String("cpp"),
            String("cxx"), String("hpp"), String("hh"), String("hxx"),
        ),
        String("cpp"), String("C++"),
    ))
    out.append(DocSpec(
        String("ruby"),
        _exts(String("rb")),
        String("ruby~3.3"), String("Ruby 3.3"),
    ))
    out.append(DocSpec(
        String("bash"),
        _exts(String("sh"), String("bash")),
        String("bash"), String("Bash"),
    ))
    out.append(DocSpec(
        String("html"),
        _exts(String("html"), String("htm")),
        String("html"), String("HTML"),
    ))
    out.append(DocSpec(
        String("css"),
        _exts(String("css")),
        String("css"), String("CSS"),
    ))

    return out^


fn find_docset_for_extension(specs: List[DocSpec], ext: String) -> Int:
    """Index of the spec whose ``file_types`` contains ``ext``, or -1."""
    if len(ext.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        for k in range(len(specs[i].file_types)):
            if specs[i].file_types[k] == ext:
                return i
    return -1


fn find_docset_by_language(
    specs: List[DocSpec], language_id: String,
) -> Int:
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1


fn docs_install_command(slug: String, dest_dir: String) -> String:
    """Shell command that mkdirs ``dest_dir`` and curls both DevDocs
    JSON files into it.

    Single ``sh -c`` line so the existing ``InstallRunner`` (which spawns
    ``sh -c <cmd>``) can run it unchanged. ``set -e`` aborts on the first
    failure so a half-fetched docset is never left on disk masquerading
    as installed — the install runner sees a non-zero exit and surfaces
    the captured curl output to the user instead of silently "succeeding".
    The two ``-f`` flags make curl exit non-zero on HTTP 4xx/5xx
    (otherwise it'd happily save a 404 HTML page as ``db.json``).
    """
    var index_url = DEVDOCS_BASE + slug + String("/index.json")
    var db_url    = DEVDOCS_BASE + slug + String("/db.json")
    var index_out = dest_dir + String("/index.json")
    var db_out    = dest_dir + String("/db.json")
    return String("set -e; mkdir -p '") + dest_dir + String("'; ") \
        + String("curl -fsSL -o '") + index_out + String("' '") \
        + index_url + String("'; ") \
        + String("curl -fsSL -o '") + db_out + String("' '") \
        + db_url + String("'")
