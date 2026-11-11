#!/usr/bin/env bash
# tests/fixtures/fake-curl.sh: stands in for curl in tests, so no network or API key is needed.
#
# It replays files from $FAKE_CURL_SCENARIO in name order, one per call.
# File names look like 01-200.json: "200" is the HTTP status to report.
# Everything it receives is logged in $FAKE_CURL_STATE for the tests to inspect:
#   args.log        command-line arguments (must never contain the API key)
#   stdin.N.log     what was sent on stdin (the --config with the key)
#   request.N.json  the request body

out="" body=""
printf '%s\n' "$*" >> "$FAKE_CURL_STATE/args.log"

# Pick out the two arguments we care about: -o FILE and --data-binary @FILE.
while (( $# > 0 )); do
  case "$1" in
    -o)            out="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
  esac
  shift
done

# Count calls in a file, because each call is a new process.
n=$(( $(cat "$FAKE_CURL_STATE/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_CURL_STATE/count"
cat > "$FAKE_CURL_STATE/stdin.$n.log"
[[ -n "$body" ]] && cp "$body" "$FAKE_CURL_STATE/request.$n.json"

# The n-th fixture file, or a 500 error when the scenario has run out.
fixture="$(find "$FAKE_CURL_SCENARIO" -name '*.json' | sort | sed -n "${n}p")"
if [[ -z "$fixture" ]]; then
  echo '{"error":{"message":"fake-curl: no more fixtures"}}' > "$out"
  printf '500'
  exit 0
fi
cp "$fixture" "$out"
name="$(basename "$fixture" .json)"
printf '%s' "${name#*-}"        # "01-200" -> "200"
