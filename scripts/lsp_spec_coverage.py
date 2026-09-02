#!/usr/bin/env python3
"""Audit turbokod's LSP client against the machine-readable spec.

LSP ships no conformance suite for *clients* — the spec repo publishes a
``metaModel.json`` instead: every request, notification, structure, property
and union variant as data. That file is the only thing that turns "do we
cover most of the protocol?" from a vibe into a number, so this script reads
it and diffs it against the source.

Three things it reports:

1. **Method inventory.** Every request / notification in the spec, split by
   direction, marked implemented or not. Exact and mechanical: a
   clientToServer method counts as implemented when the source sends it, a
   serverToClient method when the source handles it.
2. **Field coverage.** For each implemented method, the properties of its
   result/params structures that the source never mentions. This is a
   heuristic — it greps for the property name as a string literal — so treat
   a hit as "probably read" and a miss as "definitely not read".
3. **Fixture coverage.** Which methods the scenario corpus in
   ``tests/fixtures/lsp/`` actually exercises, and how many of the spec's
   union variants for that result each method's fixtures could plausibly
   cover. An indicator, not a proof.

``--check`` compares against the checked-in baseline and exits non-zero when
coverage regresses or the spec gains a method the baseline doesn't know
about; that is what makes it safe to wire into ``make check``. ``--update``
rewrites the baseline after a deliberate change.

Refresh the vendored spec with ``make update-lsp-metamodel``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
META = os.path.join(ROOT, "tests", "fixtures", "lsp", "metaModel.json")
BASELINE = os.path.join(ROOT, "tests", "fixtures", "lsp", "coverage_baseline.json")
FIXTURE_DIR = os.path.join(ROOT, "tests", "fixtures", "lsp")
SOURCES = ("lsp.mojo", "lsp_dispatch.mojo", "lsp_position.mojo")
# The host layer names some methods that ``LspManager`` only ever sees as a
# variable — ``request_navigation(method, …)`` is called from here with
# ``textDocument/typeDefinition`` / ``implementation`` / ``declaration``. It
# is scanned for the method-reference tier only, never for field coverage.
CALLER_SOURCES = SOURCES + ("desktop.mojo",)

# Methods we deliberately do not implement, with the reason. Listing one here
# is a claim that not implementing it is correct — it keeps the report's
# "unimplemented" column meaningful instead of a wall of noise nobody reads.
# Real gaps that need work *above* the protocol layer, with what it would
# take. Separate from WONT_IMPLEMENT because these aren't declined — listing
# a deferral as a decision is how a backlog disappears.
DEFERRED = {
    "workspace/diagnostic":
        "workspace-wide pull diagnostics; needs a project-diagnostics pane "
        "to show results that aren't tied to an open buffer",
    "workspace/willCreateFiles":
        "returns edits to apply *before* the operation, so the file-tree "
        "action has to become two-phase async",
    "workspace/willRenameFiles":
        "the richer half of didRenameFiles (already sent); same two-phase "
        "async requirement on the rename flow",
    "workspace/willDeleteFiles":
        "same two-phase async requirement on the delete flow",
    "window/workDoneProgress/cancel":
        "needs a cancel affordance on the progress indicator",
    "inlayHint/resolve":
        "resolve fills tooltip / textEdits / label.location; the label "
        "itself is required on the initial hint and the label is all we "
        "render, so there is nothing to fetch until tooltips exist",
    "workspaceSymbol/resolve":
        "a {uri}-only location already lands at the file's first line "
        "(see _parse_workspace_symbols_result); resolve would add the exact "
        "range. Polish, not a functional gap",
}


WONT_IMPLEMENT = {
    "textDocument/semanticTokens/full":
        "own TextMate highlighter (docs/themes.md); not advertised either",
    "textDocument/semanticTokens/full/delta": "own TextMate highlighter",
    "textDocument/semanticTokens/range": "own TextMate highlighter",
    "workspace/semanticTokens/refresh": "own TextMate highlighter",
    "notebookDocument/didOpen": "no notebook surface in either frontend",
    "notebookDocument/didChange": "no notebook surface",
    "notebookDocument/didSave": "no notebook surface",
    "notebookDocument/didClose": "no notebook surface",
    "$/setTrace":
        "we never turn on server tracing from the UI, so there is no trace "
        "level to set. The inbound half ($/logTrace) *is* handled",
    "workspace/didChangeWorkspaceFolders":
        "one project root per window by design; there is no multi-root set "
        "to change",
    "textDocument/rangesFormatting":
        "LSP 3.18 multi-range formatting; rangeFormatting covers the "
        "single-range case the editor actually issues",
    "workspace/textDocumentContent":
        "LSP 3.18 virtual documents; needs a virtual-document surface. The "
        "matching refresh request is answered",
}


def load_meta() -> dict:
    if not os.path.exists(META):
        sys.exit(
            "missing %s — run `make update-lsp-metamodel`" % os.path.relpath(META, ROOT)
        )
    with open(META) as fh:
        return json.load(fh)


def load_source(names: tuple[str, ...] = SOURCES) -> str:
    parts = []
    for name in names:
        path = os.path.join(ROOT, "src", "turbokod", name)
        if os.path.exists(path):
            with open(path) as fh:
                parts.append(fh.read())
    return "\n".join(parts)


# ``_capability_key_for_method`` maps *every* feature method to its provider
# flag, including ones we never send. Its body would otherwise make the
# weakest evidence tier ("the literal appears somewhere") match everything.
_CAP_MAP_FN = "def _capability_key_for_method"


def _strip_capability_map(src: str) -> str:
    start = src.find(_CAP_MAP_FN)
    if start < 0:
        return src
    # Function bodies here are followed by a top-level ``def`` at column 0.
    end = src.find("\ndef ", start + len(_CAP_MAP_FN))
    return src[:start] + (src[end:] if end > 0 else "")


def _sent_methods(src: str) -> set[str]:
    """Methods with a literal at an outbound call site.

    Exact: ``_send_request`` / ``_send_notification`` funnel every outbound
    message. Misses the ones dispatched through a variable — see
    ``_referenced_methods``."""
    out = set()
    for m in re.finditer(
        r'_send_(?:request|notification)\(\s*String\(\s*"([^"]+)"', src
    ):
        out.add(m.group(1))
    for m in re.finditer(r'send_request\(\s*String\(\s*"([^"]+)"', src):
        out.add(m.group(1))
    return out


def _handled_methods(src: str) -> set[str]:
    """Methods compared against an inbound ``method`` — how the notification
    and server-request dispatchers route. Read with the capability map
    stripped, since that function compares against methods too."""
    out = set()
    # ``String(`` may be followed by a newline + indent when the line was
    # wrapped, which is how ``workspace/textDocumentContent/refresh`` read as
    # unimplemented while being handled three lines above its neighbours.
    for m in re.finditer(r'method\s*==\s*String\(\s*"([^"]+)"\s*,?\s*\)',
                         _strip_capability_map(src)):
        out.add(m.group(1))
    return out


def _referenced_methods(src: str) -> set[str]:
    """Method literals appearing anywhere outside the capability map.

    The weakest evidence tier, and a necessary one: several requests are
    sent with the method in a *variable* — ``request_navigation(method, …)``
    covers typeDefinition / implementation / declaration, and the hierarchy
    flows pass ``prepareCallHierarchy`` → ``incomingCalls`` as arguments to
    ``_begin_hierarchy``. Without this tier those read as unimplemented.
    The report labels which tier each method was found by so the inference
    stays auditable."""
    return set(re.findall(r'String\("([^"/]+/[^"]+)"\)',
                          _strip_capability_map(src)))


def _mentioned(src: str) -> set[str]:
    """Every string literal in the LSP sources, for field-level heuristics."""
    return set(re.findall(r'String\("([^"]+)"\)', src))


def _resolve(meta: dict, type_node: dict, seen: set[str] | None = None) -> list[dict]:
    """Flatten a metaModel type into the concrete structures it can be.

    Returns the list of structure definitions reachable through ``or`` /
    ``array`` / ``reference`` wrappers, which is what "the union variants of
    this result" means in practice.
    """
    seen = seen if seen is not None else set()
    if not isinstance(type_node, dict):
        return []
    kind = type_node.get("kind")
    if kind == "reference":
        name = type_node["name"]
        if name in seen:
            return []
        seen.add(name)
        for s in meta["structures"]:
            if s["name"] == name:
                return [s]
        for a in meta.get("typeAliases", []):
            if a["name"] == name:
                return _resolve(meta, a["type"], seen)
        return []
    if kind == "array":
        return _resolve(meta, type_node.get("element", {}), seen)
    if kind in ("or", "and"):
        out = []
        for item in type_node.get("items", []):
            out.extend(_resolve(meta, item, seen))
        return out
    return []


def _variant_count(type_node: dict) -> int:
    """How many distinct shapes the spec permits for this type. ``null`` is
    counted — "the server may answer null" is a real variant a client has to
    survive, and historically the one that crashes editors."""
    if not isinstance(type_node, dict):
        return 0
    if type_node.get("kind") in ("or", "and"):
        return len(type_node.get("items", []))
    return 1


def _property_names(structs: list[dict]) -> set[str]:
    out = set()
    for s in structs:
        for p in s.get("properties", []):
            out.add(p["name"])
    return out


def fixture_methods() -> dict[str, list[str]]:
    """method -> the scenario files that script a response for it."""
    out: dict[str, list[str]] = {}
    if not os.path.isdir(FIXTURE_DIR):
        return out
    for name in sorted(os.listdir(FIXTURE_DIR)):
        if not name.endswith(".json") or name in ("metaModel.json",
                                                  "coverage_baseline.json"):
            continue
        with open(os.path.join(FIXTURE_DIR, name)) as fh:
            try:
                scenario = json.load(fh)
            except ValueError:
                continue
        methods = list((scenario.get("responses") or {}).keys())
        for entry in scenario.get("on_did_open") or []:
            methods.append(entry.get("method", ""))
        for entry in scenario.get("on_initialized") or []:
            methods.append(entry.get("method", ""))
        for entry in scenario.get("server_requests") or []:
            methods.append(entry.get("method", ""))
        for method in methods:
            if method:
                out.setdefault(method, []).append(name)
    return out


def audit() -> dict:
    meta = load_meta()
    src = load_source()
    callers = load_source(CALLER_SOURCES)
    sent = _sent_methods(src)
    handled = _handled_methods(src)
    referenced = _referenced_methods(callers)
    mentioned = _mentioned(src)
    fixtures = fixture_methods()

    entries = []
    for kind, items in (("request", meta["requests"]),
                        ("notification", meta["notifications"])):
        for item in items:
            method = item["method"]
            direction = item["messageDirection"]
            if direction == "serverToClient":
                evidence = "dispatch" if method in handled else ""
            elif direction == "both":
                evidence = ("dispatch" if method in handled
                            else "send-site" if method in sent else "")
            else:
                evidence = "send-site" if method in sent else ""
            if not evidence and method in referenced:
                evidence = "literal"
            implemented = bool(evidence)

            result_node = item.get("result") or item.get("params") or {}
            structs = _resolve(meta, result_node)
            props = _property_names(structs)
            unread = sorted(p for p in props if p not in mentioned)

            entries.append({
                "method": method,
                "kind": kind,
                "direction": direction,
                "implemented": implemented,
                "evidence": evidence,
                "wont_implement": WONT_IMPLEMENT.get(method),
                "deferred": DEFERRED.get(method),
                "result_variants": _variant_count(result_node),
                "result_properties": len(props),
                "unread_properties": unread if implemented else [],
                "fixtures": sorted(fixtures.get(method, [])),
            })

    entries.sort(key=lambda e: (e["kind"], e["method"]))
    impl = [e for e in entries if e["implemented"]]
    return {
        "spec_version": meta["metaData"]["version"],
        "totals": {
            "methods": len(entries),
            "implemented": len(impl),
            "with_fixtures": len([e for e in impl if e["fixtures"]]),
        },
        "methods": entries,
    }


def _fmt_report(report: dict, verbose: bool) -> str:
    t = report["totals"]
    lines = [
        "LSP %s — %d/%d methods implemented, %d covered by a scenario fixture"
        % (report["spec_version"], t["implemented"], t["methods"],
           t["with_fixtures"]),
        "",
    ]
    missing = [e for e in report["methods"]
               if not e["implemented"] and not e["wont_implement"]
               and not e["deferred"]]
    declined = [e for e in report["methods"] if e["wont_implement"]]
    deferred = [e for e in report["methods"]
                if e["deferred"] and not e["implemented"]]
    no_fixture = [e for e in report["methods"]
                  if e["implemented"] and not e["fixtures"]]

    lines.append("NOT IMPLEMENTED (%d)" % len(missing))
    for e in missing:
        lines.append("  %-46s %s %s" % (e["method"], e["kind"][:4],
                                        e["direction"]))
    if deferred:
        lines.append("")
        lines.append("DEFERRED — real gaps, need host work (%d)" % len(deferred))
        for e in deferred:
            lines.append("  %s" % e["method"])
            lines.append("    %s" % e["deferred"])
    if declined:
        lines.append("")
        lines.append("DELIBERATELY NOT IMPLEMENTED (%d)" % len(declined))
        for e in declined:
            lines.append("  %s" % e["method"])
            lines.append("    %s" % e["wont_implement"])

    lines.append("")
    lines.append("IMPLEMENTED, NO SCENARIO FIXTURE (%d)" % len(no_fixture))
    for e in no_fixture:
        lines.append("  %-46s %d spec variant(s)"
                     % (e["method"], e["result_variants"]))

    if verbose:
        lines.append("")
        lines.append("UNREAD RESULT PROPERTIES (heuristic — string-literal grep)")
        for e in report["methods"]:
            if e["implemented"] and e["unread_properties"]:
                lines.append("  %s" % e["method"])
                lines.append("    %s" % ", ".join(e["unread_properties"]))
    return "\n".join(lines)


def _comparable(report: dict) -> dict:
    """The subset of the report that a regression check is defined over.

    Property-level heuristics are deliberately excluded: they shift with
    unrelated string literals, and a check that cries wolf gets muted."""
    return {
        "spec_version": report["spec_version"],
        "implemented": sorted(e["method"] for e in report["methods"]
                              if e["implemented"]),
        "with_fixtures": sorted(e["method"] for e in report["methods"]
                                if e["implemented"] and e["fixtures"]),
        "known_methods": sorted(e["method"] for e in report["methods"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="fail if coverage regressed against the baseline")
    ap.add_argument("--update", action="store_true",
                    help="rewrite the baseline from the current source")
    ap.add_argument("--json", action="store_true", help="emit the full report")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="include the unread-property heuristic")
    args = ap.parse_args()

    report = audit()
    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    if args.update:
        with open(BASELINE, "w") as fh:
            json.dump(_comparable(report), fh, indent=2)
            fh.write("\n")
        print("wrote %s" % os.path.relpath(BASELINE, ROOT))
        print(_fmt_report(report, args.verbose))
        return 0

    print(_fmt_report(report, args.verbose))

    if not args.check:
        return 0

    if not os.path.exists(BASELINE):
        print("\nno baseline — run scripts/lsp_spec_coverage.py --update")
        return 1
    with open(BASELINE) as fh:
        base = json.load(fh)
    now = _comparable(report)
    problems = []

    lost = sorted(set(base["implemented"]) - set(now["implemented"]))
    if lost:
        problems.append("no longer implemented: %s" % ", ".join(lost))
    lost_fx = sorted(set(base["with_fixtures"]) - set(now["with_fixtures"]))
    if lost_fx:
        problems.append("lost fixture coverage: %s" % ", ".join(lost_fx))
    new_spec = sorted(set(now["known_methods"]) - set(base["known_methods"]))
    if new_spec:
        problems.append(
            "spec gained methods since the baseline (triage, then --update): %s"
            % ", ".join(new_spec)
        )
    if base["spec_version"] != now["spec_version"]:
        problems.append(
            "spec version changed %s → %s" % (base["spec_version"],
                                              now["spec_version"])
        )

    if problems:
        print("\nFAIL")
        for p in problems:
            print("  - %s" % p)
        return 1
    print("\nOK — no coverage regression")
    return 0


if __name__ == "__main__":
    sys.exit(main())
