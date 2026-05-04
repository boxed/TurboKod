"""Persistent global preferences for turbokod.

Lives at ``~/.config/turbokod/config.json``. Defaults are encoded right
here so the editor still works on a fresh checkout with no config file
present, and any failure (missing file, malformed JSON, missing keys)
silently falls back to the defaults rather than refusing to start.

Currently persists the View-menu toggles — line numbers and soft wrap.
Other settings can join later by extending ``TurbokodConfig`` plus the
load/save round-trip.
"""

from std.ffi import external_call

from .file_io import read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_object, json_str,
    parse_json,
)
from .posix import getenv_value


# Most-recently-opened project paths kept in the config. Anything past
# this is dropped when ``_set_project`` records a new entry, so the
# "Open recent project..." picker stays a manageable list.
comptime _RECENT_PROJECTS_MAX = 20


fn _config_dir() -> String:
    """Directory that holds the config file. Empty when ``$HOME`` is
    unset (e.g. inside an unusual sandbox); callers treat that as
    "no persistent config available" and skip both load and save."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod")


fn _config_path() -> String:
    var dir = _config_dir()
    if len(dir.as_bytes()) == 0:
        return String("")
    return dir + String("/config.json")


fn _ensure_dir(path: String):
    """Best-effort ``mkdir`` ignoring ``EEXIST``. We don't recurse; the
    caller attempts both ``~/.config`` and ``~/.config/turbokod`` to
    cover machines where ``~/.config`` doesn't exist yet."""
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


struct OnSaveAction(ImplicitlyCopyable, Movable):
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

    fn __init__(out self):
        self.language_id = String("")
        self.program = String("")
        self.args = List[String]()
        self.cwd = String("")

    fn __init__(
        out self, var language_id: String, var program: String,
        var args: List[String], var cwd: String,
    ):
        self.language_id = language_id^
        self.program = program^
        self.args = args^
        self.cwd = cwd^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.program = copy.program
        self.args = copy.args.copy()
        self.cwd = copy.cwd


@fieldwise_init
struct TurbokodConfig(ImplicitlyCopyable, Movable):
    """Global preferences. Defaults match the pre-config behavior."""
    var line_numbers: Bool
    var soft_wrap: Bool
    var git_changes: Bool
    var tab_bar: Bool
    # Canonical absolute paths of recently opened projects, most-recent
    # first. Updated by ``Desktop._set_project`` and surfaced via the
    # File ▸ "Open recent project..." picker.
    var recent_projects: List[String]
    # User-configured on-save actions (Settings ▸ Actions on save). The
    # editor scans this list after every successful ``_do_save`` and
    # spawns each matching entry as a one-shot subprocess. Empty by
    # default — there's no implicit "format on save" behavior.
    var on_save_actions: List[OnSaveAction]

    fn __init__(out self):
        self.line_numbers = False
        self.soft_wrap = False
        self.git_changes = False
        self.tab_bar = False
        self.recent_projects = List[String]()
        self.on_save_actions = List[OnSaveAction]()

    fn __copyinit__(out self, copy: Self):
        # ``List[String]`` isn't implicitly copyable, so the synthesized
        # copy constructor refuses — spell it out using ``List.copy``.
        self.line_numbers = copy.line_numbers
        self.soft_wrap = copy.soft_wrap
        self.git_changes = copy.git_changes
        self.tab_bar = copy.tab_bar
        self.recent_projects = copy.recent_projects.copy()
        self.on_save_actions = copy.on_save_actions.copy()


fn record_recent_project(
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


fn load_config() -> TurbokodConfig:
    """Load the saved config, or return defaults on any failure."""
    var cfg = TurbokodConfig()
    var path = _config_path()
    if len(path.as_bytes()) == 0:
        return cfg
    var info = stat_file(path)
    if not info.ok:
        return cfg
    try:
        var text = read_file(path)
        var root = parse_json(text)
        if not root.is_object():
            return cfg
        var ln = root.object_get(String("line_numbers"))
        if ln and ln.value().is_bool():
            cfg.line_numbers = ln.value().as_bool()
        var sw = root.object_get(String("soft_wrap"))
        if sw and sw.value().is_bool():
            cfg.soft_wrap = sw.value().as_bool()
        var gc = root.object_get(String("git_changes"))
        if gc and gc.value().is_bool():
            cfg.git_changes = gc.value().as_bool()
        var tb = root.object_get(String("tab_bar"))
        if tb and tb.value().is_bool():
            cfg.tab_bar = tb.value().as_bool()
        var rp = root.object_get(String("recent_projects"))
        if rp and rp.value().is_array():
            var arr = rp.value()
            for i in range(arr.array_len()):
                var item = arr.array_at(i)
                if item.is_string():
                    cfg.recent_projects.append(item.as_str())
        var osa = root.object_get(String("on_save_actions"))
        if osa and osa.value().is_array():
            var arr = osa.value()
            for i in range(arr.array_len()):
                var item = arr.array_at(i)
                if not item.is_object():
                    continue
                var act = OnSaveAction()
                var lid = item.object_get(String("language_id"))
                if lid and lid.value().is_string():
                    act.language_id = lid.value().as_str()
                var prog = item.object_get(String("program"))
                if prog and prog.value().is_string():
                    act.program = prog.value().as_str()
                var args = item.object_get(String("args"))
                if args and args.value().is_array():
                    var aarr = args.value()
                    for k in range(aarr.array_len()):
                        var av = aarr.array_at(k)
                        if av.is_string():
                            act.args.append(av.as_str())
                var cwd = item.object_get(String("cwd"))
                if cwd and cwd.value().is_string():
                    act.cwd = cwd.value().as_str()
                cfg.on_save_actions.append(act^)
    except:
        pass
    return cfg


fn save_config(config: TurbokodConfig) -> Bool:
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
    root.put(String("soft_wrap"), json_bool(config.soft_wrap))
    root.put(String("git_changes"), json_bool(config.git_changes))
    root.put(String("tab_bar"), json_bool(config.tab_bar))
    var rp = json_array()
    for i in range(len(config.recent_projects)):
        rp.append(json_str(config.recent_projects[i]))
    root.put(String("recent_projects"), rp^)
    var osa = json_array()
    for i in range(len(config.on_save_actions)):
        var act = config.on_save_actions[i]
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
    return write_file(path, encode_json(root) + String("\n"))
