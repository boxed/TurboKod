"""Language-server registry, modeled on Helix's ``languages.toml``.

A built-in catalog of common LSP servers keyed by language id, with the
file extensions that route to each language and an ordered list of
candidate binaries (with argv) so we can pick the first one the user
actually has installed.

The data is hardcoded for now — Mojo doesn't ship a TOML parser and
shelling out to one would be silly. A future extension could merge
entries from ``~/.config/turbokod/languages.toml`` (or similar) with
JSON since we already have a parser; the structure here is shaped to
make that mechanical.

Why this shape:
* Multiple ``argvs`` per language captures Python's reality (pyright,
  basedpyright, pylsp all answer the same wire protocol but ship under
  different binary names) without forcing the user to choose.
* The file-types lookup is independent of which server we end up
  spawning — extension routing stays stable even when the binary on
  PATH changes.
"""

from std.collections.list import List
from std.collections.optional import Optional


struct ServerCandidate(ImplicitlyCopyable, Movable):
    """One concrete binary + argv we can try to spawn for a language."""
    var argv: List[String]

    fn __init__(out self, var argv: List[String]):
        self.argv = argv^

    fn __copyinit__(out self, copy: Self):
        self.argv = copy.argv.copy()


struct LanguageSpec(ImplicitlyCopyable, Movable):
    """Routing entry: which file extensions belong to this language id,
    and the ordered list of server binaries to try (first hit wins).

    ``language_id`` is what ends up in ``didOpen``'s ``languageId`` field;
    ``file_types`` are matched against the lower-cased extension after
    the last ``.`` in the basename. ``install_hint`` is a one-line shell
    command we suggest to the user when none of the candidates are on
    ``$PATH`` — empty string means "no canonical install command, don't
    bother prompting" (e.g. ``mojo-lsp-server`` ships with the toolchain).
    """
    var language_id: String
    var file_types: List[String]
    var candidates: List[ServerCandidate]
    var install_hint: String

    fn __init__(
        out self, var language_id: String,
        var file_types: List[String],
        var candidates: List[ServerCandidate],
        var install_hint: String = String(""),
    ):
        self.language_id = language_id^
        self.file_types = file_types^
        self.candidates = candidates^
        self.install_hint = install_hint^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.file_types = copy.file_types.copy()
        self.candidates = copy.candidates.copy()
        self.install_hint = copy.install_hint


fn _argv1(a: String) -> ServerCandidate:
    var v = List[String]()
    v.append(a)
    return ServerCandidate(v^)


fn _argv2(a: String, b: String) -> ServerCandidate:
    var v = List[String]()
    v.append(a)
    v.append(b)
    return ServerCandidate(v^)


fn _exts(*items: String) -> List[String]:
    var out = List[String]()
    for x in items:
        out.append(String(x))
    return out^


fn built_in_servers() -> List[LanguageSpec]:
    """Curated list of well-known LSP servers + extensions.

    Order within ``candidates`` is the spawn-priority order: pyright →
    basedpyright → pylsp for Python, etc. Add to this list to teach
    turbokod about a new language. Entries that don't apply (because
    their binary isn't on ``$PATH``) are silently skipped at spawn time.
    """
    var out = List[LanguageSpec]()

    # --- Mojo ---------------------------------------------------------
    # Note: ``mojo-lsp-server`` needs ``-I`` paths injected per-project
    # to resolve internal imports. The Desktop layer adds those before
    # spawning, so the candidate here is just the bare binary.
    var mojo_cands = List[ServerCandidate]()
    mojo_cands.append(_argv1(String("mojo-lsp-server")))
    out.append(LanguageSpec(
        String("mojo"),
        _exts(String("mojo"), String("🔥")),
        mojo_cands^,
    ))

    # --- Python -------------------------------------------------------
    var py_cands = List[ServerCandidate]()
    py_cands.append(_argv2(String("pyright-langserver"), String("--stdio")))
    py_cands.append(_argv2(String("basedpyright-langserver"), String("--stdio")))
    py_cands.append(_argv1(String("pylsp")))
    out.append(LanguageSpec(
        String("python"),
        _exts(String("py"), String("pyi"), String("pyw")),
        py_cands^,
        String("pip install pyright"),
    ))

    # --- Rust ---------------------------------------------------------
    var rs_cands = List[ServerCandidate]()
    rs_cands.append(_argv1(String("rust-analyzer")))
    out.append(LanguageSpec(
        String("rust"), _exts(String("rs")), rs_cands^,
        String("rustup component add rust-analyzer"),
    ))

    # --- Go -----------------------------------------------------------
    var go_cands = List[ServerCandidate]()
    go_cands.append(_argv1(String("gopls")))
    out.append(LanguageSpec(
        String("go"), _exts(String("go")), go_cands^,
        String("go install golang.org/x/tools/gopls@latest"),
    ))

    # --- TypeScript / JavaScript -------------------------------------
    var ts_cands = List[ServerCandidate]()
    ts_cands.append(_argv2(String("typescript-language-server"), String("--stdio")))
    out.append(LanguageSpec(
        String("typescript"),
        _exts(
            String("ts"), String("tsx"), String("js"), String("jsx"),
            String("mjs"), String("cjs"),
        ),
        ts_cands^,
        String("npm install -g typescript-language-server typescript"),
    ))

    # --- C / C++ ------------------------------------------------------
    var c_cands = List[ServerCandidate]()
    c_cands.append(_argv1(String("clangd")))
    out.append(LanguageSpec(
        String("cpp"),
        _exts(
            String("c"), String("h"), String("cc"), String("cpp"),
            String("cxx"), String("hpp"), String("hh"), String("hxx"),
        ),
        c_cands^,
        String("brew install llvm  # or apt install clangd"),
    ))

    # --- Zig ----------------------------------------------------------
    var zig_cands = List[ServerCandidate]()
    zig_cands.append(_argv1(String("zls")))
    out.append(LanguageSpec(
        String("zig"), _exts(String("zig")), zig_cands^,
        String("brew install zls  # or see https://github.com/zigtools/zls"),
    ))

    # --- Ruby ---------------------------------------------------------
    var rb_cands = List[ServerCandidate]()
    rb_cands.append(_argv1(String("solargraph")))
    rb_cands.append(_argv2(String("ruby-lsp"), String("stdio")))
    out.append(LanguageSpec(
        String("ruby"), _exts(String("rb")), rb_cands^,
        String("gem install solargraph"),
    ))

    # --- JSON ---------------------------------------------------------
    var json_cands = List[ServerCandidate]()
    json_cands.append(_argv2(String("vscode-json-language-server"), String("--stdio")))
    out.append(LanguageSpec(
        String("json"),
        _exts(String("json"), String("jsonc")),
        json_cands^,
        String("npm install -g vscode-langservers-extracted"),
    ))

    # --- YAML ---------------------------------------------------------
    var yaml_cands = List[ServerCandidate]()
    yaml_cands.append(_argv2(String("yaml-language-server"), String("--stdio")))
    out.append(LanguageSpec(
        String("yaml"),
        _exts(String("yaml"), String("yml")),
        yaml_cands^,
        String("npm install -g yaml-language-server"),
    ))

    # --- Bash ---------------------------------------------------------
    var sh_cands = List[ServerCandidate]()
    sh_cands.append(_argv2(String("bash-language-server"), String("start")))
    out.append(LanguageSpec(
        String("bash"),
        _exts(String("sh"), String("bash")),
        sh_cands^,
        String("npm install -g bash-language-server"),
    ))

    return out^


fn find_language_for_extension(
    specs: List[LanguageSpec], ext: String,
) -> Int:
    """Index of the spec whose ``file_types`` contains ``ext``, or -1.

    Linear scan — the spec list is small (a couple of dozen entries
    even fully populated) and this only fires once per file open, so
    a hash table would be over-engineering.
    """
    if len(ext.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        for k in range(len(specs[i].file_types)):
            if specs[i].file_types[k] == ext:
                return i
    return -1


fn find_language_by_id(specs: List[LanguageSpec], language_id: String) -> Int:
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1
