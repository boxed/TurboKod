"""Persistent global preferences for turbokod.

Lives at ``~/.config/turbokod/config.json``. Defaults are encoded right
here so the editor still works on a fresh checkout with no config file
present, and any failure (missing file, malformed JSON, missing keys)
silently falls back to the defaults rather than refusing to start.

Persists editor preferences — line numbers, wrap mode, on-save actions,
theme, font, and more. Other settings can join later by extending
``TurbokodConfig`` plus the load/save round-trip.
"""

from std.collections.optional import Optional
from std.ffi import external_call

from .file_io import FileInfo, read_file, rename_path, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_object,
    json_str, json_get_bool, json_get_int, json_get_string,
    json_get_string_array, parse_json,
)
from .posix import getenv_value


# Wrap mode (Settings ▸ Editor). Persisted as ``TurbokodConfig.wrap_mode``
# and pushed into every editor as ``Editor.wrap_mode``. ``WRAP_NONE`` is
# horizontal-scroll; ``WRAP_SOFT`` is word-aware soft wrap; ``WRAP_SMART``
# breaks long bracketed calls one-item-per-line (falling back to soft wrap
# for unsupported languages / lines with no structure).
comptime WRAP_NONE = 0
comptime WRAP_SOFT = 1
comptime WRAP_SMART = 2

# Most-recently-opened project paths kept in the config. Anything past
# this is dropped when ``_set_project`` records a new entry, so the
# "Open recent project..." picker stays a manageable list.
comptime _RECENT_PROJECTS_MAX = 20
# Same idea for recently focused files, surfaced via the File ▸
# "Open recent..." picker. Kept larger than the project cap because
# users open far more individual files than projects in a typical
# session.
comptime _RECENT_FILES_MAX = 50


def _config_dir() -> String:
    """Directory that holds the config file. Empty when ``$HOME`` is
    unset (e.g. inside an unusual sandbox); callers treat that as
    "no persistent config available" and skip both load and save."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod")


def _config_path() -> String:
    var dir = _config_dir()
    if len(dir.as_bytes()) == 0:
        return String("")
    return dir + String("/config.json")


# Clamp range for an explicit ``font_size``. Generous on purpose — the
# point is to reject nonsense (0-adjacent and absurd sizes), not to
# police taste. Both the Settings size stepper and ``Desktop.set_font_size``
# enforce the same range.
comptime MIN_FONT_SIZE = 6
comptime MAX_FONT_SIZE = 128

# Default per-project cap on the number of open file-backed editor
# windows ("documents"). When a project would exceed this, the
# least-recently-focused clean document is closed (see
# ``Desktop._enforce_window_cap``). A value of ``0`` means "no limit".
comptime DEFAULT_MAX_OPEN_WINDOWS = 20


def default_font_label() -> String:
    """Display label for the built-in bitmap font (the ``font`` config
    field's empty-string default). Settings shows this as the first row
    of the Font list; ``Desktop.set_font`` maps it back to the empty
    string so the config file stays frontend-agnostic."""
    return String("IBM VGA 8x16 (built-in)")


def _ensure_dir(path: String):
    """Best-effort ``mkdir`` ignoring ``EEXIST``. We don't recurse; the
    caller attempts both ``~/.config`` and ``~/.config/turbokod`` to
    cover machines where ``~/.config`` doesn't exist yet."""
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


struct LanguageServerOverride(Copyable, Movable):
    """User override for one language's LSP routing.

    ``argvs`` replaces the candidate list verbatim — order is priority
    (first hit wins, just like the built-in catalog). An empty
    ``argvs`` means "this language has no server"; the built-in
    candidates are dropped.

    ``file_types`` is only consulted for languages absent from the
    built-in catalog (i.e. user-added). For overrides of built-in
    languages the catalog's file_types are preserved so the user
    doesn't lose extension routing they didn't configure.
    """
    var language_id: String
    var file_types: List[String]
    var argvs: List[List[String]]

    def __init__(out self):
        self.language_id = String("")
        self.file_types = List[String]()
        self.argvs = List[List[String]]()

    def __init__(
        out self, var language_id: String,
        var file_types: List[String],
        var argvs: List[List[String]],
    ):
        self.language_id = language_id^
        self.file_types = file_types^
        self.argvs = argvs^

    def __copyinit__(mut self, copy: Self):
        self.language_id = copy.language_id
        self.file_types = copy.file_types.copy()
        var argvs = List[List[String]]()
        for i in range(len(copy.argvs)):
            argvs.append(copy.argvs[i].copy())
        self.argvs = argvs^


struct OnSaveAction(Copyable, Movable):
    """One configured "after a successful save, run this" action.

    ``language_id`` empty matches every save; otherwise the action only
    fires when the saved file's extension resolves (via the LSP language
    registry) to that language.

    ``program`` is the absolute path to the binary; ``args`` is the list
    of CLI arguments passed verbatim. ``cwd`` empty means "use the
    project root" (or the saved file's parent when no project is open).

    Pure data — Desktop owns the runner.
    """
    var language_id: String
    var program: String
    var args: List[String]
    var cwd: String

    def __init__(out self):
        self.language_id = String("")
        self.program = String("")
        self.args = List[String]()
        self.cwd = String("")

    def __init__(
        out self, var language_id: String, var program: String,
        var args: List[String], var cwd: String,
    ):
        self.language_id = language_id^
        self.program = program^
        self.args = args^
        self.cwd = cwd^

    def __copyinit__(mut self, copy: Self):
        self.language_id = copy.language_id
        self.program = copy.program
        self.args = copy.args.copy()
        self.cwd = copy.cwd


@fieldwise_init
struct TurbokodConfig(Copyable, Movable):
    """Global preferences. Defaults match the pre-config behavior."""
    var line_numbers: Bool
    # Wrap mode: ``WRAP_NONE`` / ``WRAP_SOFT`` / ``WRAP_SMART`` (see the
    # module-level constants). Replaces the old binary ``soft_wrap`` bool;
    # legacy configs that still carry ``soft_wrap: true`` migrate to
    # ``WRAP_SOFT`` on load.
    var wrap_mode: Int
    # Settings ▸ Editor ▸ "Smart wrap: break at commas". Extra smart-wrap
    # break trigger: a bracketed call with *more than* this many top-level
    # commas is broken one-item-per-line even when it fits the window. ``-1``
    # (the default, shown as an empty input) disables it — only window width
    # triggers a break. Only consulted by ``WRAP_SMART``.
    var smart_wrap_comma_threshold: Int
    var git_changes: Bool
    var tab_bar: Bool
    # Right-side minimap gutter: a fixed-height projection of the whole
    # file that surfaces uncommitted-change markers regardless of
    # ``scroll_y``. The gutter only paints when there's data to show
    # (currently: git change lines), so flipping it on outside a repo
    # is a silent no-op.
    var minimap: Bool
    # Sticky scroll: pin the enclosing-scope header lines (indentation
    # chain above the viewport top) to the top of the editor.
    var sticky_scroll: Bool
    # Settings ▸ Editor ▸ Save behavior. ``True`` (default) saves every
    # dirty file-backed buffer on focus loss — whether the wrapper
    # window loses focus or the user switches between editor windows
    # inside the app. ``False`` opts out, leaving Ctrl+S as the only
    # write path.
    var auto_save: Bool
    # Settings ▸ Editor toggles, both default ``True``. They act as the
    # global fallback for the matching editorconfig properties: an
    # explicit ``.editorconfig`` value always wins, but when the file's
    # editorconfig leaves the property unset the editor uses these.
    #   ``trim_trailing_whitespace`` — strip trailing spaces/tabs from
    #     every line on save.
    #   ``ensure_final_newline`` — guarantee the saved file ends in a
    #     newline. Off means "leave whatever's there" (it never strips a
    #     trailing newline — that stays an editorconfig-only behavior).
    var trim_trailing_whitespace: Bool
    var ensure_final_newline: Bool
    # Settings ▸ Editor ▸ "Compress keyword arguments". When on, lines that
    # don't hold the caret render redundant ``name=name`` call arguments with
    # the label concealed (``foo(a=a)`` → ``foo(=a)``); the buffer is
    # untouched. Off by default. See ``kwarg_conceal.mojo``.
    var compress_kwargs: Bool
    # Settings ▸ Editor ▸ "Blinking cursor". When on, the editor caret
    # blinks (~530 ms half-cycle) instead of showing as a steady block; it
    # snaps back to solid on any keystroke / click so it's never mid-blink
    # right when you start typing. On by default — matches the classic
    # text-mode cursor and keeps the caret easy to spot.
    var cursor_blink: Bool
    # Settings ▸ Language Server. Per-feature gates for the optional,
    # non-user-initiated LSP capabilities. Each only takes effect when the
    # active server also advertises the matching provider. Mixed defaults:
    # cheap/quiet features (signature help, document highlight, server
    # progress) start on; heavier or more intrusive ones start off.
    var lsp_format_on_save: Bool      # run textDocument/formatting on save
    var lsp_signature_help: Bool      # param-hints popup on '('/',' (default on)
    var lsp_document_highlight: Bool  # highlight occurrences at cursor (default on)
    var lsp_document_links: Bool      # clickable document links
    var lsp_inlay_hints: Bool         # inline type/param-name hints
    var lsp_code_lens: Bool           # actionable inline annotations
    var lsp_document_colors: Bool     # color swatches
    var lsp_linked_editing: Bool      # co-edit matching ranges (e.g. tags)
    var lsp_server_progress: Bool     # show server work progress (default on)
    # Settings ▸ Theme. Name of the active color theme (see ``theme.mojo``).
    # Drives both syntax highlighting and the UI chrome palette. Defaults to
    # the classic ``"Turbo C++ 3.0"`` look; an unknown name (e.g. a config
    # written by a newer build) falls back to the default at load time.
    var theme: String
    # Settings ▸ Font (native macOS frontend only). Family name of the
    # monospace font the Swift host renders cells with. Empty means the
    # bundled Px437 IBM VGA bitmap font. The terminal frontend ignores it
    # — the terminal emulator owns the font there.
    var font: String
    # Settings ▸ Font size in points (native macOS frontend only). 0 means
    # "the font's default size" — 16 for the bundled bitmap font (its
    # design size), 13 for system monospace families — so a config that
    # never touched the size keeps each font's natural default when the
    # family changes.
    var font_size: Int
    # Per-project cap on simultaneously-open file-backed editor windows.
    # Once a project hits this, opening another document closes the
    # least-recently-focused clean (saved) document; session restore
    # likewise reopens only the most-recently-used documents up to this
    # count. ``0`` disables the cap. Default ``DEFAULT_MAX_OPEN_WINDOWS``.
    var max_open_windows: Int
    # Canonical absolute paths of recently opened projects, most-recent
    # first. Updated by ``Desktop._set_project`` and surfaced via the
    # File ▸ "Open recent project..." picker.
    var recent_projects: List[String]
    # Canonical absolute paths of recently focused file-backed editors,
    # most-recent first. Updated by ``Desktop._track_recent_focus``
    # whenever the focused file changes, and surfaced via the File ▸
    # "Open recent..." picker so the entries persist across sessions.
    var recent_files: List[String]
    # User-configured on-save actions (Settings ▸ Actions on save). The
    # editor scans this list after every successful ``_do_save`` and
    # spawns each matching entry as a one-shot subprocess. Empty by
    # default — there's no implicit "format on save" behavior.
    var on_save_actions: List[OnSaveAction]
    # Per-language LSP overrides (Settings ▸ Languages). Replaces the
    # built-in candidate list for any language the user has touched;
    # languages not present here pass through the bundled catalog
    # unchanged.
    var language_servers: List[LanguageServerOverride]

    def __init__(out self):
        self.line_numbers = False
        self.wrap_mode = WRAP_NONE
        self.smart_wrap_comma_threshold = -1
        self.git_changes = False
        self.tab_bar = False
        self.minimap = True
        self.sticky_scroll = True
        self.auto_save = True
        self.trim_trailing_whitespace = True
        self.ensure_final_newline = True
        self.compress_kwargs = False
        self.cursor_blink = True
        self.lsp_format_on_save = False
        self.lsp_signature_help = True
        self.lsp_document_highlight = True
        self.lsp_document_links = False
        self.lsp_inlay_hints = False
        self.lsp_code_lens = False
        self.lsp_document_colors = False
        self.lsp_linked_editing = False
        self.lsp_server_progress = True
        self.theme = String("Turbo C++ 3.0")
        self.font = String("")
        self.font_size = 0
        self.max_open_windows = DEFAULT_MAX_OPEN_WINDOWS
        self.recent_projects = List[String]()
        self.recent_files = List[String]()
        self.on_save_actions = List[OnSaveAction]()
        self.language_servers = List[LanguageServerOverride]()

    def __copyinit__(mut self, copy: Self):
        # ``List[String]`` isn't implicitly copyable, so the synthesized
        # copy constructor refuses — spell it out using ``List.copy``.
        self.line_numbers = copy.line_numbers
        self.wrap_mode = copy.wrap_mode
        self.smart_wrap_comma_threshold = copy.smart_wrap_comma_threshold
        self.git_changes = copy.git_changes
        self.tab_bar = copy.tab_bar
        self.minimap = copy.minimap
        self.sticky_scroll = copy.sticky_scroll
        self.auto_save = copy.auto_save
        self.trim_trailing_whitespace = copy.trim_trailing_whitespace
        self.ensure_final_newline = copy.ensure_final_newline
        self.compress_kwargs = copy.compress_kwargs
        self.cursor_blink = copy.cursor_blink
        self.lsp_format_on_save = copy.lsp_format_on_save
        self.lsp_signature_help = copy.lsp_signature_help
        self.lsp_document_highlight = copy.lsp_document_highlight
        self.lsp_document_links = copy.lsp_document_links
        self.lsp_inlay_hints = copy.lsp_inlay_hints
        self.lsp_code_lens = copy.lsp_code_lens
        self.lsp_document_colors = copy.lsp_document_colors
        self.lsp_linked_editing = copy.lsp_linked_editing
        self.lsp_server_progress = copy.lsp_server_progress
        self.theme = copy.theme
        self.font = copy.font
        self.font_size = copy.font_size
        self.max_open_windows = copy.max_open_windows
        self.recent_projects = copy.recent_projects.copy()
        self.recent_files = copy.recent_files.copy()
        self.on_save_actions = copy.on_save_actions.copy()
        self.language_servers = copy.language_servers.copy()


def record_recent_project(
    mut config: TurbokodConfig, var path: String,
) -> Bool:
    """Promote ``path`` to the front of ``config.recent_projects``,
    dedup any existing entry, and cap the list at
    ``_RECENT_PROJECTS_MAX``. Returns True iff the list actually changed —
    callers use this to skip a redundant ``save_config`` when the project
    is already at the front (mirrors ``record_recent_file``). Empty paths
    are ignored."""
    if len(path.as_bytes()) == 0:
        return False
    if len(config.recent_projects) > 0 and config.recent_projects[0] == path:
        return False
    var new_list = List[String]()
    new_list.append(path)
    for i in range(len(config.recent_projects)):
        if config.recent_projects[i] != path:
            new_list.append(config.recent_projects[i])
    while len(new_list) > _RECENT_PROJECTS_MAX:
        _ = new_list.pop(len(new_list) - 1)
    config.recent_projects = new_list^
    return True


def record_recent_file(
    mut config: TurbokodConfig, var path: String,
) -> Bool:
    """Promote ``path`` to the front of ``config.recent_files``, dedup
    any existing entry, and cap at ``_RECENT_FILES_MAX``. Returns True
    iff the list actually changed — callers use this to skip a redundant
    ``save_config`` write when the focused file is already at the
    front. Empty paths are ignored."""
    if len(path.as_bytes()) == 0:
        return False
    if len(config.recent_files) > 0 and config.recent_files[0] == path:
        return False
    var new_list = List[String]()
    new_list.append(path)
    for i in range(len(config.recent_files)):
        if config.recent_files[i] != path:
            new_list.append(config.recent_files[i])
    while len(new_list) > _RECENT_FILES_MAX:
        _ = new_list.pop(len(new_list) - 1)
    config.recent_files = new_list^
    return True


@fieldwise_init
struct ConfigLoad(Copyable, Movable):
    """Result of ``load_config``: the config plus whether it's safe to
    persist back over the file on disk.

    ``persistable`` is the whole point of this struct. ``load_config``
    returns defaults in *three* very different situations — fresh install
    (no file), ``$HOME`` unset (no persistent config at all), and a file
    that *exists but couldn't be read/parsed*. The first two are benign:
    writing defaults later is correct. The third is a trap — if the editor
    treats a failed load as "user has default settings" and then saves on
    the next file focus / theme change, the atomic write destroys whatever
    the user actually had. So on an unreadable existing file we move it
    aside (preserving it for manual recovery) and only set ``persistable``
    if that succeeded; if we couldn't get it out of the way, the caller
    must refuse to overwrite it."""
    var config: TurbokodConfig
    var persistable: Bool


def _move_config_aside(path: String) -> Bool:
    """Rename an unreadable config to ``config.json.corrupt[.N]`` so it's
    preserved for recovery and the next save can start clean. Returns True
    if the file was moved out of the way (or already gone)."""
    var base = path + String(".corrupt")
    var target = base
    var n = 1
    while stat_file(target).ok:
        target = base + String(".") + String(n)
        n += 1
        if n > 100:
            return False
    return rename_path(path, target)


def _on_load_failed(path: String) -> ConfigLoad:
    """An existing config file couldn't be read/parsed. Move it aside and
    return defaults that are persistable only if we got the file out of the
    way — otherwise refuse to overwrite it on the next save."""
    var moved = _move_config_aside(path)
    return ConfigLoad(TurbokodConfig(), moved)


def _config_from_json(root: JsonValue) raises -> TurbokodConfig:
    """Parse a config object into a ``TurbokodConfig``.

    Raises on anything it can't read, and only ever returns a *fully*
    parsed config — a mid-parse error must not yield a half-merged hybrid
    of file values and defaults. Callers decide what a failure means:
    ``load_config`` moves the file aside for recovery, while the
    merge-on-save and change-watcher paths just skip this round.
    """
    var cfg = TurbokodConfig()
    if not root.is_object():
        raise Error("config: root is not a JSON object")
    cfg.line_numbers = json_get_bool(
        root, String("line_numbers"), cfg.line_numbers,
    )
    # ``wrap_mode`` (int) is authoritative; fall back to the legacy
    # ``soft_wrap`` bool so configs written by older builds still wrap.
    var legacy_soft = WRAP_SOFT if json_get_bool(
        root, String("soft_wrap"), False,
    ) else WRAP_NONE
    cfg.wrap_mode = json_get_int(
        root, String("wrap_mode"), legacy_soft,
    )
    cfg.smart_wrap_comma_threshold = json_get_int(
        root, String("smart_wrap_comma_threshold"),
        cfg.smart_wrap_comma_threshold,
    )
    cfg.git_changes = json_get_bool(
        root, String("git_changes"), cfg.git_changes,
    )
    cfg.tab_bar = json_get_bool(root, String("tab_bar"), cfg.tab_bar)
    cfg.minimap = json_get_bool(root, String("minimap"), cfg.minimap)
    cfg.sticky_scroll = json_get_bool(
        root, String("sticky_scroll"), cfg.sticky_scroll,
    )
    cfg.auto_save = json_get_bool(
        root, String("auto_save"), cfg.auto_save,
    )
    cfg.trim_trailing_whitespace = json_get_bool(
        root, String("trim_trailing_whitespace"),
        cfg.trim_trailing_whitespace,
    )
    cfg.ensure_final_newline = json_get_bool(
        root, String("ensure_final_newline"),
        cfg.ensure_final_newline,
    )
    cfg.compress_kwargs = json_get_bool(
        root, String("compress_kwargs"), cfg.compress_kwargs,
    )
    cfg.cursor_blink = json_get_bool(
        root, String("cursor_blink"), cfg.cursor_blink,
    )
    cfg.lsp_format_on_save = json_get_bool(
        root, String("lsp_format_on_save"), cfg.lsp_format_on_save,
    )
    cfg.lsp_signature_help = json_get_bool(
        root, String("lsp_signature_help"), cfg.lsp_signature_help,
    )
    cfg.lsp_document_highlight = json_get_bool(
        root, String("lsp_document_highlight"),
        cfg.lsp_document_highlight,
    )
    cfg.lsp_document_links = json_get_bool(
        root, String("lsp_document_links"), cfg.lsp_document_links,
    )
    cfg.lsp_inlay_hints = json_get_bool(
        root, String("lsp_inlay_hints"), cfg.lsp_inlay_hints,
    )
    cfg.lsp_code_lens = json_get_bool(
        root, String("lsp_code_lens"), cfg.lsp_code_lens,
    )
    cfg.lsp_document_colors = json_get_bool(
        root, String("lsp_document_colors"), cfg.lsp_document_colors,
    )
    cfg.lsp_linked_editing = json_get_bool(
        root, String("lsp_linked_editing"), cfg.lsp_linked_editing,
    )
    cfg.lsp_server_progress = json_get_bool(
        root, String("lsp_server_progress"), cfg.lsp_server_progress,
    )
    var theme_v = json_get_string(root, String("theme"))
    if len(theme_v.as_bytes()) > 0:
        cfg.theme = theme_v
    cfg.font = json_get_string(root, String("font"))
    cfg.font_size = json_get_int(
        root, String("font_size"), cfg.font_size,
    )
    # 0 means "use the default"; any explicit size is clamped to the
    # same range the stepper / set_font_size enforce, so a corrupt or
    # hand-edited config can't briefly push a negative or absurd size
    # to the host at startup.
    if cfg.font_size != 0:
        if cfg.font_size < MIN_FONT_SIZE:
            cfg.font_size = MIN_FONT_SIZE
        elif cfg.font_size > MAX_FONT_SIZE:
            cfg.font_size = MAX_FONT_SIZE
    cfg.max_open_windows = json_get_int(
        root, String("max_open_windows"), cfg.max_open_windows,
    )
    # Negative is meaningless — fold it into "no limit" (0) so a
    # corrupt or hand-edited config can't wedge the cap below zero.
    if cfg.max_open_windows < 0:
        cfg.max_open_windows = 0
    cfg.recent_projects = json_get_string_array(
        root, String("recent_projects"),
    )
    cfg.recent_files = json_get_string_array(
        root, String("recent_files"),
    )
    var osa = root.object_get(String("on_save_actions"))
    if osa and osa.value().is_array():
        var arr = osa.value().copy()
        for i in range(arr.array_len()):
            var item = arr.array_at(i)
            if not item.is_object():
                continue
            var act = OnSaveAction()
            act.language_id = json_get_string(item, String("language_id"))
            act.program = json_get_string(item, String("program"))
            act.args = json_get_string_array(item, String("args"))
            act.cwd = json_get_string(item, String("cwd"))
            cfg.on_save_actions.append(act^)
    var lsv = root.object_get(String("language_servers"))
    if lsv and lsv.value().is_array():
        var arr = lsv.value().copy()
        for i in range(arr.array_len()):
            var item = arr.array_at(i)
            if not item.is_object():
                continue
            var ov = LanguageServerOverride()
            ov.language_id = json_get_string(item, String("language_id"))
            if len(ov.language_id.as_bytes()) == 0:
                continue
            ov.file_types = json_get_string_array(
                item, String("file_types"),
            )
            var argvs_v = item.object_get(String("argvs"))
            if argvs_v and argvs_v.value().is_array():
                var aa = argvs_v.value().copy()
                for k in range(aa.array_len()):
                    var inner = aa.array_at(k)
                    if not inner.is_array():
                        continue
                    var argv = List[String]()
                    for m in range(inner.array_len()):
                        var s = inner.array_at(m)
                        if s.is_string():
                            argv.append(s.as_str())
                    if len(argv) > 0:
                        ov.argvs.append(argv^)
            cfg.language_servers.append(ov^)
    return cfg^


def try_read_config() -> Optional[TurbokodConfig]:
    """Non-destructive read of the config file. ``None`` when there is no
    file, or it can't be read or parsed.

    Unlike ``load_config`` this never moves a bad file aside. It backs the
    two paths that run continuously — the merge in ``save_config_merged``
    and ``Desktop``'s change watcher — and neither may perform one-shot
    recovery as a side effect of a routine poll.
    """
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return Optional[TurbokodConfig]()
    if not stat_file(path).ok:
        return Optional[TurbokodConfig]()
    try:
        var cfg = _config_from_json(parse_json(read_file(path)))
        return Optional[TurbokodConfig](cfg^)
    except:
        return Optional[TurbokodConfig]()


def config_file_stamp() -> FileInfo:
    """``stat`` of the config file, used by the change watcher to spot a
    write by another window or another turbokod process. ``ok=False``
    when there's no ``$HOME`` or no file yet."""
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return FileInfo(Int64(0), Int64(0), UInt32(0), False)
    return stat_file(path)


def load_config() -> ConfigLoad:
    """Load the saved config. See ``ConfigLoad`` for why this returns a
    persistability flag rather than a bare config — a failed read must not
    be laundered into a destructive save-back of defaults."""
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return ConfigLoad(TurbokodConfig(), True)
    if not stat_file(path).ok:
        # Fresh install — no file yet. Writing defaults later is correct.
        return ConfigLoad(TurbokodConfig(), True)
    try:
        var cfg = _config_from_json(parse_json(read_file(path)))
        return ConfigLoad(cfg^, True)
    except e:
        # The file exists but read/parse raised. Log, move it aside, and
        # return defaults that won't clobber the original (see ConfigLoad).
        print("config: load_config:", String(e))
        return _on_load_failed(path)


def _config_to_json(config: TurbokodConfig) -> JsonValue:
    """Serialize a config to the JSON object written to disk. Split out of
    ``save_config`` so the merge path can round-trip through the same
    encoding the loader parses."""
    var root = json_object()
    root.put(String("line_numbers"), json_bool(config.line_numbers))
    root.put(String("wrap_mode"), json_int(config.wrap_mode))
    root.put(
        String("smart_wrap_comma_threshold"),
        json_int(config.smart_wrap_comma_threshold),
    )
    root.put(String("git_changes"), json_bool(config.git_changes))
    root.put(String("tab_bar"), json_bool(config.tab_bar))
    root.put(String("minimap"), json_bool(config.minimap))
    root.put(String("sticky_scroll"), json_bool(config.sticky_scroll))
    root.put(String("auto_save"), json_bool(config.auto_save))
    root.put(
        String("trim_trailing_whitespace"),
        json_bool(config.trim_trailing_whitespace),
    )
    root.put(
        String("ensure_final_newline"),
        json_bool(config.ensure_final_newline),
    )
    root.put(String("compress_kwargs"), json_bool(config.compress_kwargs))
    root.put(String("cursor_blink"), json_bool(config.cursor_blink))
    root.put(
        String("lsp_format_on_save"), json_bool(config.lsp_format_on_save),
    )
    root.put(
        String("lsp_signature_help"), json_bool(config.lsp_signature_help),
    )
    root.put(
        String("lsp_document_highlight"),
        json_bool(config.lsp_document_highlight),
    )
    root.put(
        String("lsp_document_links"), json_bool(config.lsp_document_links),
    )
    root.put(String("lsp_inlay_hints"), json_bool(config.lsp_inlay_hints))
    root.put(String("lsp_code_lens"), json_bool(config.lsp_code_lens))
    root.put(
        String("lsp_document_colors"),
        json_bool(config.lsp_document_colors),
    )
    root.put(
        String("lsp_linked_editing"), json_bool(config.lsp_linked_editing),
    )
    root.put(
        String("lsp_server_progress"),
        json_bool(config.lsp_server_progress),
    )
    root.put(String("theme"), json_str(config.theme))
    root.put(String("font"), json_str(config.font))
    root.put(String("font_size"), json_int(config.font_size))
    root.put(
        String("max_open_windows"), json_int(config.max_open_windows),
    )
    var rp = json_array()
    for i in range(len(config.recent_projects)):
        rp.append(json_str(config.recent_projects[i]))
    root.put(String("recent_projects"), rp^)
    var rf = json_array()
    for i in range(len(config.recent_files)):
        rf.append(json_str(config.recent_files[i]))
    root.put(String("recent_files"), rf^)
    var osa = json_array()
    for i in range(len(config.on_save_actions)):
        var act = config.on_save_actions[i].copy()
        var obj = json_object()
        obj.put(String("language_id"), json_str(act.language_id))
        obj.put(String("program"), json_str(act.program))
        var aarr = json_array()
        for k in range(len(act.args)):
            aarr.append(json_str(act.args[k]))
        obj.put(String("args"), aarr^)
        obj.put(String("cwd"), json_str(act.cwd))
        osa.append(obj^)
    root.put(String("on_save_actions"), osa^)
    var lsv = json_array()
    for i in range(len(config.language_servers)):
        var ov = config.language_servers[i].copy()
        var obj = json_object()
        obj.put(String("language_id"), json_str(ov.language_id))
        var ft = json_array()
        for k in range(len(ov.file_types)):
            ft.append(json_str(ov.file_types[k]))
        obj.put(String("file_types"), ft^)
        var aa = json_array()
        for k in range(len(ov.argvs)):
            var inner = json_array()
            for m in range(len(ov.argvs[k])):
                inner.append(json_str(ov.argvs[k][m]))
            aa.append(inner^)
        obj.put(String("argvs"), aa^)
        lsv.append(obj^)
    root.put(String("language_servers"), lsv^)
    return root^


def _write_config(config: TurbokodConfig) -> Bool:
    """Encode and atomically write ``config``, creating ``~/.config`` and
    ``~/.config/turbokod`` if they don't exist yet. ``write_file`` does the
    temp-file + ``rename(2)`` dance, so a failed write can't truncate the
    existing config."""
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return False
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) > 0:
        _ensure_dir(home + String("/.config"))
    _ensure_dir(_config_dir())
    return write_file(path, encode_json(_config_to_json(config)) + String("\n"))


def save_config(config: TurbokodConfig) -> Bool:
    """Write ``config`` to ``~/.config/turbokod/config.json``, replacing
    whatever is there. Returns True on success.

    This is the unconditional overwrite. Anything holding a config that
    was loaded earlier — i.e. every ``Desktop`` — must go through
    ``save_config_merged`` instead, or it writes a stale whole-file
    snapshot over changes made since. See ``merge_config``.
    """
    return _write_config(config)


# --- concurrent writers -------------------------------------------------
#
# The config file has many writers: one ``Desktop`` per window in the
# native app (plus the always-alive chrome Desktop that drives the menu
# bar with no window open), and one per ``tk-tui`` process. Each holds its
# own ``TurbokodConfig`` loaded when it was created, and each writes the
# *whole* file. Without the three-way merge below, the last writer won —
# so changing the theme in one window and then merely switching files in
# another (which persists the recents list) reverted the theme.


# ``flock(2)`` operations — same values on Darwin and Linux.
comptime _LOCK_EX = Int32(2)
comptime _LOCK_UN = Int32(8)


def _lock_path() -> String:
    var dir = _config_dir()
    if len(dir.as_bytes()) == 0:
        return String("")
    return dir + String("/config.lock")


def _acquire_config_lock() -> Int32:
    """Take an exclusive ``flock`` on ``~/.config/turbokod/config.lock``,
    returning the held descriptor or ``-1``.

    This serializes the read-merge-write against other turbokod processes
    (windows within one process are single-threaded, so they can't
    interleave). Failing to lock is not fatal — we still merge and write,
    we just lose the cross-process serialization, which is no worse than
    the behavior before the lock existed.

    ``creat(2)`` rather than ``open(2)`` because ``open`` is variadic and
    so unreachable through ``external_call`` (the same reason
    ``write_file`` uses it). Truncating the lock file is harmless: it is
    always empty, the lock lives in the kernel and not in the bytes.
    """
    var path = _lock_path()
    if len(path.as_bytes()) == 0:
        return Int32(-1)
    var c_path = path + String("\0")
    var fd = external_call["creat", Int32](c_path.unsafe_ptr(), Int32(0o644))
    if fd < 0:
        return Int32(-1)
    if external_call["flock", Int32](fd, _LOCK_EX) != Int32(0):
        _ = external_call["close", Int32](fd)
        return Int32(-1)
    return fd


def _release_config_lock(fd: Int32):
    if fd < 0:
        return
    _ = external_call["flock", Int32](fd, _LOCK_UN)
    _ = external_call["close", Int32](fd)


def _str_lists_equal(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def lsp_overrides_equal(
    a: List[LanguageServerOverride], b: List[LanguageServerOverride],
) -> Bool:
    """Structural equality for the per-language LSP overrides. Used to
    decide whether adopting a merged config has to rebuild the language
    server routing."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i].language_id != b[i].language_id:
            return False
        if not _str_lists_equal(a[i].file_types, b[i].file_types):
            return False
        if len(a[i].argvs) != len(b[i].argvs):
            return False
        for k in range(len(a[i].argvs)):
            if not _str_lists_equal(a[i].argvs[k], b[i].argvs[k]):
                return False
    return True


def _merge_recents(
    disk: List[String], mine: List[String], base: List[String], cap: Int,
) -> List[String]:
    """Merge one most-recent-first path list.

    Untouched by us → take the file's copy wholesale. Touched → keep our
    order (our promotion is the newest event we know of) and append the
    entries only the file has, so a path another window opened is
    preserved rather than dropped.
    """
    if _str_lists_equal(mine, base):
        return disk.copy()
    var out = mine.copy()
    for i in range(len(disk)):
        var seen = False
        for k in range(len(out)):
            if out[k] == disk[i]:
                seen = True
                break
        if not seen:
            out.append(disk[i])
    while len(out) > cap:
        _ = out.pop(len(out) - 1)
    return out^


def _merge_json_objects(
    disk: JsonValue, mine: JsonValue, base: JsonValue,
) -> JsonValue:
    """Key-wise three-way merge of two flat config objects.

    A key whose value differs from the baseline is one we changed, so ours
    wins; every other key keeps whatever the file holds. Values compare by
    their encoding, which covers the nested arrays (``on_save_actions``,
    ``language_servers``) with no per-field code.

    Merging over the JSON rather than over ``TurbokodConfig``'s fields is
    deliberate. A hand-written field-by-field merge is only correct while
    somebody remembers to extend it: a field left out would resolve to
    "unchanged" on every save, so the setting would be reverted the
    instant it was written — silently, and only for the fields nobody
    thought about. Driving it off the serializer means a field that
    persists at all is merged too.
    """
    var out = disk.copy()
    for i in range(mine.object_len()):
        var key = mine.object_key_at(i)
        var mine_v = mine.object_value_at(i)
        var base_v = base.object_get(key)
        if base_v and encode_json(base_v.value()) == encode_json(mine_v):
            continue
        out.put(key, mine_v^)
    return out^


def merge_config(
    disk: TurbokodConfig, mine: TurbokodConfig, base: TurbokodConfig,
) -> TurbokodConfig:
    """Three-way merge of the config.

    ``base`` is what *this* holder last read from (or wrote to) disk,
    ``mine`` is its current in-memory state, and ``disk`` is what the file
    holds now. Fields we changed win; everything else takes the on-disk
    value. That is what lets another window's — or another process's —
    change survive our write instead of being reverted by our stale
    snapshot.

    Simultaneous edits of the *same* field still resolve last-writer-wins.
    The point is that editing *different* fields no longer conflicts, and
    in this config nearly every field is a separate setting.
    """
    var merged = _merge_json_objects(
        _config_to_json(disk), _config_to_json(mine), _config_to_json(base),
    )
    try:
        var out = _config_from_json(merged)
        # The recents are the one pair that merges rather than replaces:
        # the generic key merge would drop the entries only the other
        # writer has, and those are just as real as ours.
        out.recent_projects = _merge_recents(
            disk.recent_projects, mine.recent_projects, base.recent_projects,
            _RECENT_PROJECTS_MAX,
        )
        out.recent_files = _merge_recents(
            disk.recent_files, mine.recent_files, base.recent_files,
            _RECENT_FILES_MAX,
        )
        return out^
    except:
        # Unreachable — we just built ``merged`` with the same encoder the
        # parser round-trips. Keeping ours is the safe fallback regardless:
        # it's what every save did before the merge existed.
        return mine.copy()


@fieldwise_init
struct ConfigSave(Copyable, Movable):
    """Result of ``save_config_merged``: whether the write landed, and the
    config as it now stands on disk. Callers adopt ``config`` as both their
    live config and their new merge baseline — it carries any change another
    writer made that they hadn't seen yet."""
    var ok: Bool
    var config: TurbokodConfig


def save_config_merged(
    config: TurbokodConfig, baseline: TurbokodConfig,
) -> ConfigSave:
    """Persist ``config`` without clobbering concurrent writers.

    Locks, re-reads the file, three-way merges our changes over it (see
    ``merge_config``), and writes the result. An unreadable file on disk
    falls back to writing ours verbatim — recovery of a corrupt config is
    ``load_config``'s job, and refusing to save at all would leave the user
    unable to change any setting.
    """
    var lock = _acquire_config_lock()
    var merged = config.copy()
    var current = try_read_config()
    if current:
        merged = merge_config(current.value(), config, baseline)
    var ok = _write_config(merged)
    _release_config_lock(lock)
    return ConfigSave(ok, merged^)
