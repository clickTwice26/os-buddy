# lib/load.sh: loads every library file, in the right order.
# Used by bin/os-buddy and by the tests, so the list lives in one place.
#
#   core/   shared basics: messages, text helpers, settings, drawing
#   admin/  the admin reports (disk, health, ...): no AI, no API key
#   ai/     the AI agent: safety policy, Gemini API, tools, agent loop
#
# Order matters only inside a group: a file may use functions from the
# files listed before it.

OSBUDDY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _file in \
  core/ui core/text core/config core/viz \
  admin/common admin/disk admin/health admin/proc admin/backup admin/users admin/status \
  ai/policy ai/gemini ai/tools ai/agent ai/render
do
  # shellcheck source=/dev/null
  source "$OSBUDDY_LIB/$_file.sh" || { echo "os-buddy: cannot load lib/$_file.sh" >&2; exit 1; }
done
unset _file
