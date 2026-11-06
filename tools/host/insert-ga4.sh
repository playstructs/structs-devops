#!/usr/bin/env bash
# Insert the site's GA4 tag into the CURRENT templates/base.html.twig. Never
# overlay a saved copy of the template: upstream changes it (hashed bundles).
. "$(dirname "$0")/_bundle.sh"

GA="${GA4_ID:?GA4_ID not set for $SITE_ID}"
TWIG="${WEBAPP_SRC:?}/templates/base.html.twig"
LABEL="${GA4_LABEL:-${OIDC_ISSUER#https://}}"
[ -f "$TWIG" ] || { echo "FATAL: $TWIG missing" >&2; exit 1; }

python3 - "$TWIG" "$GA" "${LABEL:-$SITE_ID}" <<'PY'
import re, shutil, sys
from datetime import datetime
path, ga, label = sys.argv[1:4]
t = open(path, encoding="utf-8").read()
if f"gtag/js?id={ga}" in t and f"gtag('config', '{ga}')" in t:
    print(f"  gtag {ga} already present")
    sys.exit(0)
shutil.copy2(path, f"{path}.bak.{datetime.now():%Y%m%dT%H%M%S}")
if "googletagmanager.com/gtag/js" in t:
    lines = [re.sub(r"G-[A-Z0-9]+", ga, l) if ("gtag" in l or "googletagmanager" in l) else l
             for l in t.split("\n")]
    t = "\n".join(lines)
    print(f"  gtag ids normalized to {ga}")
else:
    needle = '<meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1">'
    if needle not in t:
        sys.exit("FATAL: viewport meta not found for the gtag insert; manual review")
    snippet = f'''        <!-- Google tag (gtag.js) — {label} -->
        <script async src="https://www.googletagmanager.com/gtag/js?id={ga}"></script>
        <script>
            window.dataLayer = window.dataLayer || [];
            function gtag(){{dataLayer.push(arguments);}}
            gtag('js', new Date());
            gtag('config', '{ga}');
        </script>
'''
    t = t.replace(needle, needle + "\n\n" + snippet, 1)
    print(f"  inserted gtag {ga}")
with open(path, "w", encoding="utf-8") as f:
    f.write(t)
PY
grep -q "gtag('config', '$GA')" "$TWIG"
