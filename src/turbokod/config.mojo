"""Persistent global preferences for turbokod.

Lives at ``~/.config/turbokod/config.json``. Defaults are encoded right
here so the editor still works on a fresh checkout with no config file
present, and any failure (missing file, malformed JSON, missing keys)
silently falls back to the defaults rather than refusing to start.

Persists editor preferences — line numbers, wrap mode, on-save actions,
theme, font, and more. Other settings can join later by extending
``TurbokodConfig`` plus the load/save round-trip.
"""

from std.ffi import external_call

from .file_io import read_file, stat_file, write_file
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
        self.auto_save = True
        self.trim_trailing_whitespace = True
        self.ensure_final_newline = True
        self.compress_kwargs = False
        self.theme = String("Turbo C++ 3.0")
        self.font = String("")
        self.font_size = 0
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
        self.auto_save = copy.auto_save
        self.trim_trailing_whitespace = copy.trim_trailing_whitespace
        self.ensure_final_newline = copy.ensure_final_newline
        self.compress_kwargs = copy.compress_kwargs
        self.theme = copy.theme
        self.font = copy.font
        self.font_size = copy.font_size
        self.recent_projects = copy.recent_projects.copy()
        self.recent_files = copy.recent_files.copy()
        self.on_save_actions = copy.on_save_actions.copy()
        self.language_servers = copy.language_servers.copy()


def record_recent_project(
    mut config: TurbokodConfig, var path: String,
):
    """Promote ``path`` to the front of ``config.recent_projects``,
    dedup any existing entry, and cap the list at
    ``_RECENT_PROJECTS_MAX``. Empty paths are ignored."""
    if len(path.as_bytes()) == 0:
        return
    var new_list = List[String]()
    new_list.append(path)
    for i in range(len(config.recent_projects)):
        if config.recent_projects[i] != path:
            new_list.append(config.recent_projects[i])
    while len(new_list) > _RECENT_PROJECTS_MAX:
        _ = new_list.pop(len(new_list) - 1)
    config.recent_projects = new_list^


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


def load_config() -> TurbokodConfig:
    """Load the saved config, or return defaults on any failure."""
    var cfg = TurbokodConfig()
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return cfg^
    var info = stat_file(path)
    if not info.ok:
        return cfg^
    try:
        var text = read_file(path)
        var root = parse_json(text)
        if not root.is_object():
            return cfg^
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
        var theme_v = json_get_string(root, String("theme"))
        if len(theme_v.as_bytes()) > 0:
            cfg.theme = theme_v
        cfg.font = json_get_string(root, String("font"))
        cfg.font_size = json_get_int(
            root, String("font_size"), cfg.font_size,
        )
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
    except e:
        # Defaults-on-failure is the contract — but log so a
        # corrupt/unparseable config doesn't disappear into the void.
        print("config: load_config:", String(e))
    return cfg^


def save_config(config: TurbokodConfig) -> Bool:
    """Write ``config`` to ``~/.config/turbokod/config.json``. Returns
    True on success. Creates ``~/.config`` and ``~/.config/turbokod``
    if they don't exist yet."""
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return False
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) > 0:
        _ensure_dir(home + String("/.config"))
    _ensure_dir(_config_dir())
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
    root.put(String("theme"), json_str(config.theme))
    root.put(String("font"), json_str(config.font))
    root.put(String("font_size"), json_int(config.font_size))
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
    return write_file(path, encode_json(root) + String("\n"))
