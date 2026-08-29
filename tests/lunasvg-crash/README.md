# lunasvg crash regression

`samples/` are the six public fuzz samples from
[sammycage/lunasvg#209](https://github.com/sammycage/lunasvg/issues/209), taken from the reporter's
[`keepinggg/poc`](https://github.com/keepinggg/poc) repository. Three of them segfault the pinned
lunasvg 3.5.0 at a 50x50 render, and they segfault lunasvg master too — upstream's "all reported
vulnerabilities have been fixed" does not hold for these.

That matters here more than it does for a command-line converter: Kodi decodes images in-process,
so a SIGSEGV in the renderer takes the whole application down and there is nothing an add-on can
catch.

The fix is carried in `depends/common/lunasvg/` and submitted upstream as
[lunasvg#269](https://github.com/sammycage/lunasvg/pull/269). `run.sh` builds the pinned tarball
twice — untouched and with this repo's patches applied — then checks that no sample crashes the
patched build and that valid SVGs in `valid/` render byte-identically either way, so the guard
cannot be masking a rendering regression.

Run it locally with `tests/lunasvg-crash/run.sh`; CI runs it on every push.
