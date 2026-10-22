#!/usr/bin/env bash
# TLS probe for the 1.19.1 certificate fix, per James's test plan.
#
# Usage: probe.sh [LABEL]
#   PROBE_TOOLS  dir with bin/{curl,git,python3,node,goprobe} (default: $HOME/probe-tools)
#   PROBE_NIX    nix binary to test (default: `nix` on PATH; "skip" to skip)
#
# Classifies by error text, never by exit code alone:
#   R = rejected with a certificate/TLS error (a pass against the bad host)
#   A = TLS handshake succeeded (any HTTP status, "repo not found", ...)
#   ? = failed for some other reason (DNS, timeout, missing tool) -> look at it
# A run is VOID unless every tool scores A against the github.com control.

BAD="https://dv-g3b-emudhra.we-have-a-problem.com/"
GOOD="https://github.com/"
T="${PROBE_TOOLS:-$HOME/probe-tools}/bin"
NIX="${PROBE_NIX:-$(command -v nix || true)}"
CERT_RE='trust anchor|certificate|SSL|ssl|TLS|tls|CERT_|self.signed|issuer|verify'

echo "=== probe ${1:-} | $(date -u +%FT%TZ) | $(uname -m) | shell=$(ps -o comm= -p $PPID 2>/dev/null)"
for v in SSL_CERT_FILE NIX_SSL_CERT_FILE SSL_CERT_DIR; do
  val="${!v-<unset>}"
  res=""
  [ "$val" != "<unset>" ] && [ -e "$val" ] && res=" -> $(readlink -f "$val")"
  echo "  $v=$val$res"
done

classify() { # $1 = combined output, $2 = "ok" if the tool reported TLS success
  if [ "$2" = ok ]; then echo A
  elif grep -qE "$CERT_RE" <<<"$1"; then echo R
  else echo "?"
  fi
}

run() { # name, url
  local name=$1 url=$2 out ok=""
  case $name in
    curl)
      out=$("$T/curl" -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>&1) && ok=ok ;;
    host-curl)
      [ -x /usr/bin/curl ] || { echo "-"; return; }
      out=$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>&1) && ok=ok ;;
    git)
      out=$(GIT_TERMINAL_PROMPT=0 timeout 30 "$T/git" ls-remote "$url" 2>&1)
      # TLS succeeded if git got as far as an HTTP-level answer.
      grep -qiE 'not found|not appear to be a git|HTTP|returned error|repository' <<<"$out" \
        && ! grep -qiE "$CERT_RE" <<<"$out" && ok=ok ;;
    python)
      out=$("$T/python3" -c '
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(sys.argv[1], timeout=20); print("HTTP ok")
except urllib.error.HTTPError as e:
    print("HTTP", e.code)
except Exception as e:
    print("ERR", repr(e)); sys.exit(1)' "$url" 2>&1) && ok=ok ;;
    node)
      out=$("$T/node" -e '
require("https").get(process.argv[1], r => { console.log("HTTP", r.statusCode); process.exit(0) })
  .on("error", e => { console.log("ERR", e.code, e.message); process.exit(1) })' "$url" 2>&1) && ok=ok ;;
    go)
      out=$("$T/goprobe" "$url" 2>&1) && ok=ok ;;
    nix)
      [ -n "$NIX" ] && [ "$NIX" != skip ] || { echo "-"; return; }
      out=$(timeout 60 "$NIX" --extra-experimental-features nix-command \
        store prefetch-file --name probe --hash-type sha256 "$url" 2>&1)
      if [ $? -eq 0 ] || { grep -qE 'HTTP error [0-9]+' <<<"$out" && ! grep -qiE "$CERT_RE" <<<"$out"; }; then ok=ok; fi ;;
  esac
  local c
  c=$(classify "$out" "$ok")
  echo "$c"
  # Evidence for every non-A verdict, so a report never shows a bare letter.
  [ "$c" != A ] && echo "    [$name $c] $(tr '\n' ' ' <<<"$out" | cut -c1-240)" >&2
}

void=""
printf '  %-10s %-4s %-4s\n' tool bad ctl
for tool in curl git python node go nix host-curl; do
  b=$(run $tool "$BAD")
  g=$(run $tool "$GOOD")
  [ "$g" = A ] || [ "$g" = - ] || void="$void $tool"
  printf '  %-10s %-4s %-4s\n' "$tool" "$b" "$g"
done
[ -n "$void" ] && echo "  VOID: control failed for:$void"
echo "=== end"
