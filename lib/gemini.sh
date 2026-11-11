# lib/gemini.sh: one call to the Gemini generateContent REST API.
# The request and response live in files, so big JSON never passes
# through command-line arguments (limits, quoting bugs).

# Tests replace curl with a fake by setting OSBUDDY_CURL.
: "${OSBUDDY_CURL:=curl}"
: "${OSBUDDY_RETRY_DELAY:=2}"      # first retry wait in seconds, doubles each time
: "${OSBUDDY_RETRIES:=4}"          # total attempts for 429 / 5xx

# Build the request body.
#   $1 history file (JSON array of contents)
#   $2 system prompt file (plain text)
#   $3 tool declarations file (JSON array)
#   $4 output file
gemini_build_request() {
  jq -n \
    --slurpfile history "$1" \
    --rawfile system "$2" \
    --slurpfile tools "$3" \
    '{
      systemInstruction: { parts: [ { text: $system } ] },
      contents: $history[0],
      tools: [ { functionDeclarations: $tools[0] } ]
    }' > "$4"
}

# Send a request file, save the response to a file.
#   $1 request file   $2 response file
# Returns 0 on success, 1 on failure (message already printed).
gemini_call() {
  local req="$1" resp="$2" url code attempt=1 delay="$OSBUDDY_RETRY_DELAY" msg
  url="$OSBUDDY_API_BASE/models/$OSBUDDY_MODEL:generateContent"

  while true; do
    # The key goes in on stdin (--config -), so it never shows in "ps".
    code="$(printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" |
      "$OSBUDDY_CURL" --silent --show-error --config - \
        --max-time 300 \
        -X POST -H 'Content-Type: application/json' \
        --data-binary @"$req" \
        -o "$resp" -w '%{http_code}' \
        "$url")" || code="000"          # 000 = network error, no HTTP reply

    ui_debug "HTTP $code (attempt $attempt)"
    [[ "$code" == 200 ]] && return 0

    # 429 = rate limit, 5xx = server trouble, 000 = network: worth retrying.
    if [[ "$code" =~ ^(429|5..|000)$ ]] && (( attempt < OSBUDDY_RETRIES )); then
      ui_warn "Gemini API returned $code, retrying in ${delay}s..."
      sleep "$delay"
      delay=$(( delay * 2 ))           # exponential backoff
      attempt=$(( attempt + 1 ))
      continue
    fi

    # Give up. Show the server's own error message if there is one.
    msg="$(jq -r '.error.message // empty' "$resp" 2>/dev/null)"
    ui_error "Gemini API error (HTTP $code): ${msg:-no details}"
    return 1
  done
}
