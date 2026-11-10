#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate docs/api.html from the four modules of this repository, and fill the
# numbers the front pages show. The public surface comes from `pkg.generated.mbti`,
# so a declaration cannot be left out or invented; the prose comes from the `///`
# comments in the sources, which the interface format does not carry.
#
#   moon info --target js                     # in the root and each drivers/*
#   moon info --target native                 # the transports that only build there
#   python3 scripts/gen_api.py                # write the page and the numbers
#
# The shell it fills is `scripts/api.template.html`: the generator's input lives with
# the generator, so the published site holds only pages a reader can open.
#   python3 scripts/gen_api.py --check        # exit 1 if either is stale
#
# A package that only builds on one backend has no canonical `pkg.generated.mbti`
# (the compiler writes that from the module's own preferred backend), so its
# interface is read from the check output of that backend.

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# module key, module title, what the module is, and its packages as
# (directory under the module, full package name, label, anchor)
MODULES = [
    (
        "moonsd",
        "moonsd",
        "the contract: three traits, two helpers, a registry in this process and the suite every backend runs",
        [
            ("src", "moonbitstack/moonsd", "moonsd", "moonsd"),
            ("src/memory", "moonbitstack/moonsd/memory", "memory", "moonsd-memory"),
            ("src/conformance", "moonbitstack/moonsd/conformance", "conformance", "moonsd-conformance"),
        ],
    ),
    (
        "moonredis",
        "moonredis",
        "a Redis client, and the contract carried by expiring keys",
        [
            ("drivers/redis/src", "moonbitstack/moonredis", "moonredis", "moonredis"),
            ("drivers/redis/src/resp", "moonbitstack/moonredis/resp", "resp", "moonredis-resp"),
            ("drivers/redis/src/socket", "moonbitstack/moonredis/socket", "socket", "moonredis-socket"),
            ("drivers/redis/src/sd", "moonbitstack/moonredis/sd", "sd", "moonredis-sd"),
        ],
    ),
    (
        "moonetcd",
        "moonetcd",
        "an etcd client, and the contract on keys attached to leases",
        [
            ("drivers/etcd/src", "moonbitstack/moonetcd", "moonetcd", "moonetcd"),
            ("drivers/etcd/src/client", "moonbitstack/moonetcd/client", "client", "moonetcd-client"),
            ("drivers/etcd/src/concurrency", "moonbitstack/moonetcd/concurrency", "concurrency", "moonetcd-concurrency"),
            ("drivers/etcd/src/sd", "moonbitstack/moonetcd/sd", "sd", "moonetcd-sd"),
        ],
    ),
    (
        "moonconsul",
        "moonconsul",
        "a Consul client, and the contract as services with ttl checks",
        [
            ("drivers/consul/src", "moonbitstack/moonconsul", "moonconsul", "moonconsul"),
            ("drivers/consul/src/fetch", "moonbitstack/moonconsul/fetch", "fetch", "moonconsul-fetch"),
            ("drivers/consul/src/concurrency", "moonbitstack/moonconsul/concurrency", "concurrency", "moonconsul-concurrency"),
            ("drivers/consul/src/sd", "moonbitstack/moonconsul/sd", "sd", "moonconsul-sd"),
        ],
    ),
]

# The pages whose numbers are generated rather than typed.
NUMBER_PAGES = ["docs/index.html"]

TYPE_KINDS = {"struct", "enum", "trait", "suberror", "type"}
VALUE_KINDS = {"let", "const"}

# Members a `#derive(...)` or a trait implementation adds carry no documentation of
# their own and are not what a reader looks up; they are listed together, folded
# away, so the page still shows every declaration.
DERIVED = {"equal", "not_equal", "to_repr", "to_string", "output"}

DECL_RE = re.compile(
    r"^pub(?:\([^)]*\))?\s+"
    r"(?:async\s+)?"
    r"(struct|enum|trait|suberror|type|fn|const|let|impl|using)\s*"
    r"(?:\[[^\]]*\]\s*)?"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)?"
)

# The site says what this library does, not what it was read from: a declaration
# whose prose names another implementation fails the build instead of leaking.
FOREIGN = (
    "go-zero", "Kratos", "kratos", "discov", "zeromicro", "redis-py", "go-redis",
    "SQLAlchemy", "Django", "GORM", "Celery", "Hibernate", "Diesel", "Serde",
    "Python", "Rust", "Go's", "Tokio", "Node.js",
)


def _esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _balance(text):
    return text.count("{") - text.count("}"), text.count("(") - text.count(")")


def parse_mbti(path):
    """Every public declaration in a package, as (kind, key, signature)."""
    out = []
    buf = None
    depth = (0, 0)
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            s = line.strip()
            if buf is None:
                if not (s.startswith("pub ") or s.startswith("pub(")):
                    continue
                m = DECL_RE.match(line)
                if not m:
                    continue
                buf = line
                depth = _balance(line)
                if depth <= (0, 0):
                    out.append((m.group(1), m.group(2) or "", _tidy(buf)))
                    buf = None
            else:
                buf += "\n" + line
                brace, paren = _balance(line)
                depth = (depth[0] + brace, depth[1] + paren)
                if depth <= (0, 0):
                    m = DECL_RE.match(buf)
                    out.append(
                        (
                            m.group(1) if m else "fn",
                            (m.group(2) if m else "") or "",
                            _tidy(buf),
                        )
                    )
                    buf = None
    if buf is not None:
        m = DECL_RE.match(buf)
        out.append((m.group(1), m.group(2) or "", _tidy(buf)))
    return out


def _tidy(sig):
    """An interface the reader can copy: a body of private fields says so."""
    lines = [line.rstrip() for line in sig.splitlines()]
    if len(lines) > 1 and all(
        line.strip().startswith("//") or not line.strip() for line in lines[1:]
    ):
        return lines[0].rstrip() + " { /* private */ }"
    return "\n".join(lines)


def parse_docs(pkg_dir):
    """key -> doc text, from the `///` blocks in a package's sources."""
    docs = {}
    for base, _dirs, files in os.walk(pkg_dir):
        if "examples" in base.split(os.sep) or "integration" in base.split(os.sep):
            continue
        for name in sorted(files):
            if not name.endswith(".mbt") or name.endswith(("_test.mbt", "_wbtest.mbt")):
                continue
            path = os.path.join(base, name)
            pending = []
            with open(path, encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.rstrip("\n")
                    s = line.strip()
                    if s.startswith("///"):
                        text = s[3:].strip()
                        if text != "|":
                            pending.append(text)
                        continue
                    if s.startswith("#"):
                        # an attribute sits between the doc comment and the declaration
                        continue
                    if not s:
                        if pending:
                            pending.append("")
                        continue
                    if pending and s.startswith("pub"):
                        m = DECL_RE.match(line)
                        if m and m.group(2):
                            body = "\n".join(pending).strip()
                            if body:
                                docs.setdefault(m.group(2), body)
                    pending = []
    return docs


def foreign(text):
    """The names in `FOREIGN` that appear as words, so `discovery` is not `discov`."""
    return [
        name
        for name in FOREIGN
        if re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", text)
    ]


def _inline(text):
    text = _esc(text)
    text = re.sub(r"\[(`[^`]+`)\]", r"\1", text)
    text = re.sub(r"`([^`]+)`", r'<code class="inline">\1</code>', text)
    text = re.sub(r"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])", r"<em>\1</em>", text)
    return text


def render_doc(text):
    """`///` prose as paragraphs, with fenced examples kept as they are."""
    if not text:
        return ""
    chunks, para, code = [], [], None
    for line in text.splitlines():
        stripped = line.strip()
        if code is not None:
            if stripped.startswith("```"):
                chunks.append("<pre><code>" + _esc("\n".join(code)) + "</code></pre>")
                code = None
            else:
                code.append(line.rstrip())
            continue
        if stripped.startswith("```"):
            if para:
                chunks.append("<p>" + _inline(" ".join(para)) + "</p>")
                para = []
            code = []
            continue
        if not stripped:
            if para:
                chunks.append("<p>" + _inline(" ".join(para)) + "</p>")
                para = []
            continue
        para.append(stripped)
    if code:
        chunks.append("<pre><code>" + _esc("\n".join(code)) + "</code></pre>")
    if para:
        chunks.append("<p>" + _inline(" ".join(para)) + "</p>")
    return "".join(chunks)


def render_entry(kind, key, sig, doc):
    name = key.split("::")[-1]
    body = render_doc(doc)
    return (
        f'<div class="entry" data-name="{_esc(key).lower()} {_esc(kind)}">'
        f'<pre class="sig">{_esc(sig)}</pre>'
        + (f'<div class="doc">{body}</div>' if body else "")
        + "</div>"
    )


def render_package(full, label, anchor, entries, docs, counts):
    types = sorted(
        [e for e in entries if e[0] in TYPE_KINDS and e[1] in docs], key=lambda e: e[1].lower()
    )
    typed = sorted([e for e in entries if e[0] in TYPE_KINDS], key=lambda e: e[1].lower())
    fns = sorted(
        [
            e
            for e in entries
            if e[0] == "fn"
            and not (e[1].split("::")[-1] in DERIVED and not docs.get(e[1]))
        ],
        key=lambda e: e[1].lower(),
    )
    values = sorted([e for e in entries if e[0] in VALUE_KINDS], key=lambda e: e[1].lower())
    impls = sorted([e for e in entries if e[0] == "impl"], key=lambda e: e[2].lower())
    reexports = sorted([e for e in entries if e[0] == "using"], key=lambda e: e[2].lower())
    derived = sorted(
        [
            e
            for e in entries
            if e[0] == "fn"
            and e[1].split("::")[-1] in DERIVED
            and not docs.get(e[1])
        ],
        key=lambda e: e[1].lower(),
    )
    unknown = [
        e for e in entries if e[0] not in TYPE_KINDS | VALUE_KINDS | {"fn", "impl", "using"}
    ]
    if unknown:
        raise SystemExit(f"{full}: cannot group {unknown[0][2].splitlines()[0]}")
    shown = len(typed) + len(fns) + len(values) + len(impls) + len(derived) + len(reexports)
    if shown != len(entries):
        raise SystemExit(
            f"{full}: {len(entries)} declarations, {shown} of them grouped; fix render_package"
        )
    counts["total"] += len(entries)

    out = [f'<section class="pkg" id="{anchor}">']
    out.append(
        f'<div class="pkg__head"><h3>{_esc(label)}</h3>'
        f'<span class="n">{len(entries)} items · {_esc(full)}</span></div>'
    )
    for title, group in (
        ("Types", typed),
        ("Values", values),
        ("Functions &amp; methods", fns),
        ("Implementations", impls),
        ("Re-exports", reexports),
    ):
        if not group:
            continue
        out.append(f'<div class="pkg__group">{title} <span class="n">{len(group)}</span></div>')
        for kind, key, sig in group:
            out.append(render_entry(kind, key, sig, docs.get(key, "")))
    if derived:
        out.append(
            f'<details class="derived"><summary>Derived members'
            f'<span class="n">{len(derived)}</span></summary><div class="derived__list">'
        )
        for kind, key, sig in derived:
            out.append(f'<div class="entry entry--derived" data-name="{_esc(key).lower()} derived">'
                       f'<pre class="sig">{_esc(sig)}</pre></div>')
        out.append("</div></details>")
    out.append("</section>")
    return "\n".join(out)


def mbti_path(dir_rel, full):
    committed = os.path.join(ROOT, dir_rel, "pkg.generated.mbti")
    if os.path.exists(committed):
        return committed
    parts = full.split("/")
    checked = os.path.join(ROOT, "_build", "native", "debug", "check", *parts, parts[-1] + ".mbti")
    if os.path.exists(checked):
        return checked
    return None


def build():
    sections, nav = [], []
    counts = {"total": 0}
    per_module = {}
    packages = 0
    for key, title, blurb, pkgs in MODULES:
        body = []
        module_total = 0
        links = []
        for dir_rel, full, label, anchor in pkgs:
            path = mbti_path(dir_rel, full)
            if path is None:
                raise SystemExit(
                    f"no interface for {full}: run moon info in the module that holds it"
                )
            entries = parse_mbti(path)
            if not entries:
                raise SystemExit(f"{full}: the interface lists nothing public, which cannot be right")
            declared = sum(1 for line in open(path, encoding="utf-8") if line.startswith("pub"))
            if declared != len(entries):
                raise SystemExit(
                    f"{full}: the interface declares {declared} public items, the page parsed {len(entries)}"
                )
            docs = parse_docs(os.path.join(ROOT, dir_rel))
            # The compiler is the authority on what is public; the sources on what it
            # means. Anything the page would print that names another implementation
            # stops the build rather than shipping.
            for kind, name, sig in entries:
                text = docs.get(name, "")
                leaked = foreign(text) + foreign(name)
                if leaked:
                    raise SystemExit(
                        f"{full}: the doc of {name or sig.splitlines()[0]} names {', '.join(sorted(set(leaked)))}"
                    )
            before = counts["total"]
            body.append(render_package(full, label, anchor, entries, docs, counts))
            module_total += counts["total"] - before
            packages += 1
            links.append(f'<a href="#{anchor}">{_esc(label)}<span class="n">{len(entries)}</span></a>')
        per_module[key] = module_total
        sections.append(
            f'<section class="mod" id="{key}">'
            f'<div class="mod__head"><h2>{_esc(title)}</h2>'
            f'<span class="folio">{module_total} public items</span></div>'
            f'<p style="color:var(--ink-soft);max-width:70ch">{_esc(blurb)}</p>'
            + "\n".join(body)
            + "</section>"
        )
        nav.append(
            f'<div class="grp">{_esc(title)}</div>'
            + "\n".join(links)
        )
    return "\n".join(nav), "\n".join(sections), counts["total"], packages, per_module


GEN_ATTR = re.compile(r'(<(\w+)([^>]*?)data-gen="([^"]+)"[^>]*>)([^<]*)(</\2>)')


def fill_numbers(files, total, packages, per_module):
    values = {
        "modules": str(len(MODULES)),
        "packages": str(packages),
        "items": str(total),
    }
    for key, count in per_module.items():
        values[f"items:{key}"] = str(count)
    changed = []
    for rel in files:
        path = os.path.join(ROOT, rel)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        def swap(m):
            key = m.group(4)
            if key not in values:
                raise SystemExit(f"{rel}: no number is generated for data-gen=\"{key}\"")
            return m.group(1) + values[key] + m.group(6)

        updated = GEN_ATTR.sub(swap, text)
        if updated != text:
            changed.append(rel)
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(updated)
    return changed


def main():
    check = "--check" in sys.argv
    nav, sections, total, packages, per_module = build()
    with open(os.path.join(ROOT, "scripts/api.template.html"), encoding="utf-8") as fh:
        shell = fh.read()
    page = (
        shell.replace("{NAV}", nav)
        .replace("{SECTIONS}", sections)
        .replace("{TOTAL}", str(total))
        .replace("{PACKAGES}", str(packages))
    )
    out_path = os.path.join(ROOT, "docs/api.html")
    current = ""
    if os.path.exists(out_path):
        with open(out_path, encoding="utf-8") as fh:
            current = fh.read()

    stale = []
    if current != page:
        stale.append("docs/api.html")
        if not check:
            with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(page)

    if check:
        # the numbers the front pages show have to be the ones this run counted
        for rel in NUMBER_PAGES:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
                text = fh.read()
            for m in GEN_ATTR.finditer(text):
                key = m.group(4)
                want = {"modules": str(len(MODULES)), "packages": str(packages), "items": str(total)}.get(
                    key, per_module.get(key.removeprefix("items:"))
                )
                if want is not None and m.group(5) != str(want):
                    stale.append(f"{rel} ({key}: {m.group(5)} not {want})")
    else:
        stale += fill_numbers(NUMBER_PAGES, total, packages, per_module)

    for key, count in per_module.items():
        print(f"{key}: {count} public items")
    print(f"{packages} packages, {total} public items")
    if stale:
        if check:
            sys.stderr.write(", ".join(stale) + " stale; run python3 scripts/gen_api.py\n")
        else:
            print("updated: " + ", ".join(stale))
        return 1 if check else 0
    print("docs/api.html is up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
