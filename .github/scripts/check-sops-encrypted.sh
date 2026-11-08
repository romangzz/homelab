#!/usr/bin/env bash
# Fails if a secret could reach git in plaintext:
#   - a *.sops.yaml document with a data/stringData value that isn't ENC[...]
#     (e.g. edited with a plain editor instead of `sops`), or one missing its
#     sops metadata block (mac)
#   - a SopsSecret outside a *.sops.yaml file (.sops.yaml's creation rules
#     only encrypt *.sops.yaml, so it would be committed unencrypted)
#   - a plain `kind: Secret` carrying data/stringData outside *.sops.yaml
#
# Usage: check-sops-encrypted.sh [file ...]
#   No args: every tracked YAML under apps/ and clusters/ (what CI runs).
#   With args: just those files (what the pre-commit hook runs).
# Plain POSIX awk on purpose: Ubuntu runners ship mawk, not gawk.
#   File args are resolved relative to the current directory.
set -euo pipefail

if [ $# -eq 0 ]; then
  cd "$(git rev-parse --show-toplevel)"
  mapfile -t files < <(git ls-files 'apps/*.yaml' 'apps/*.yml' 'clusters/*.yaml' 'clusters/*.yml')
else
  files=("$@")
fi

fail=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.yaml|*.yml) ;;
    *) continue ;;
  esac
  case "$f" in
    *.sops.yaml|*.sops.yml) is_sops=1 ;;
    *) is_sops=0 ;;
  esac

  if ! awk -v file="$f" -v is_sops="$is_sops" '
    function reset() { kind=""; has_sops=0; has_mac=0; nvals=0; nplain=0; plain=""; inblock=0 }
    function finish(   doc) {
      doc = "document " docn
      if (is_sops) {
        if (nplain > 0)               { printf "%s (%s): plaintext value(s) for:%s -- edit with `sops %s`\n", file, doc, plain, file; bad=1 }
        if (nvals > 0 && !(has_sops && has_mac)) { printf "%s (%s): has data but no sops metadata -- not encrypted with sops\n", file, doc; bad=1 }
      } else {
        if (kind == "SopsSecret")     { printf "%s (%s): SopsSecret must live in a *.sops.yaml file\n", file, doc; bad=1 }
        if (kind == "Secret" && nvals > 0) { printf "%s (%s): plain Secret with data -- use a *.sops.yaml SopsSecret or a generator\n", file, doc; bad=1 }
      }
    }
    BEGIN { reset(); docn=1; bad=0 }
    /^---/ { finish(); reset(); docn++; next }
    /^[ \t]*(#.*)?$/ { next }
    {
      match($0, /^ */); ind = RLENGTH
      if ($0 ~ /^kind:[ \t]*/) { k=$0; sub(/^kind:[ \t]*/, "", k); sub(/[ \t].*$/, "", k); kind=k }
      if ($0 ~ /^sops:/) { has_sops=1 }
      if ($0 ~ /^[ ]+mac:[ \t]*ENC\[/) { has_mac=1 }

      if (inblock && ind <= blockind) { inblock=0 }
      if (inblock) {
        line=$0; sub(/^ */, "", line)
        if (line ~ /^[^:#][^:]*:/) {
          key=line; sub(/:.*$/, "", key)
          val=line; sub(/^[^:]*:[ \t]*/, "", val)
          if (val != "") {
            nvals++
            if (val !~ /^ENC\[/) { nplain++; plain = plain " " key }
          }
        }
        next
      }
      if ($0 ~ /^ *(data|stringData):[ \t]*$/) { inblock=1; blockind=ind }
    }
    END { finish(); exit bad }
  ' "$f"; then
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "Plaintext secret check failed (see docs/secrets-migration.md)." >&2
fi
exit "$fail"
