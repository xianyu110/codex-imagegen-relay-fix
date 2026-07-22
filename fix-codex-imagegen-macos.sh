#!/bin/sh

set -eu
umask 077

relay_base_url="${CODEX_RELAY_BASE_URL:-https://codex.maynor1024.live/v1}"
launch_agent_label='com.maynor.codex-imagegen-env'
native_codex='/Applications/Codex.app/Contents/Resources/codex'

if [ "$(uname -s)" != 'Darwin' ]; then
  echo 'ERROR: This script is for macOS only.' >&2
  exit 1
fi

codex_home="${CODEX_HOME:-$HOME/.codex}"
config_file="$codex_home/config.toml"
auth_file="$codex_home/auth.json"
env_helper="$codex_home/bin/codex-imagegen-env.sh"
launch_agent="$HOME/Library/LaunchAgents/$launch_agent_label.plist"

if [ ! -f "$config_file" ]; then
  echo "ERROR: Missing $config_file" >&2
  exit 1
fi

if [ ! -f "$auth_file" ]; then
  echo "ERROR: Missing $auth_file" >&2
  echo 'Set OPENAI_API_KEY in auth.json locally, then rerun this script.' >&2
  exit 1
fi

relay_key="$(/usr/bin/plutil -extract OPENAI_API_KEY raw -- "$auth_file" 2>/dev/null || true)"
if [ -z "$relay_key" ]; then
  echo 'ERROR: OPENAI_API_KEY(auth.json)=MISSING' >&2
  exit 1
fi
echo 'OPENAI_API_KEY(auth.json)=EXISTS'

active_provider="$(awk -F= '
  /^[[:space:]]*model_provider[[:space:]]*=/ {
    value=$2
    sub(/^[[:space:]]*/, "", value)
    sub(/[[:space:]]*$/, "", value)
    gsub(/^"|"$/, "", value)
    print value
    exit
  }
' "$config_file")"

if [ -z "$active_provider" ]; then
  echo 'ERROR: model_provider is not configured.' >&2
  exit 1
fi

provider_section="[model_providers.$active_provider]"
if ! grep -Fqx "$provider_section" "$config_file"; then
  echo "ERROR: Missing $provider_section" >&2
  exit 1
fi

config_mode="$(stat -f '%Lp' "$config_file")"
config_tmp="$(mktemp "$config_file.tmp.XXXXXX")"

cleanup_config_tmp() {
  if [ -f "$config_tmp" ]; then
    unlink "$config_tmp"
  fi
}
trap cleanup_config_tmp EXIT HUP INT TERM

awk -v provider_section="$provider_section" \
    -v provider_name="$active_provider" \
    -v relay_base_url="$relay_base_url" '
  function emit_provider() {
    print "name = \"" provider_name "\""
    print "base_url = \"" relay_base_url "\""
    print "wire_api = \"responses\""
    print "requires_openai_auth = false"
    print "env_key = \"OPENAI_API_KEY\""
    print "http_headers = { \"x-openai-actor-authorization\" = \"local-relay\" }"
  }

  function emit_image_feature() {
    print "image_generation = true"
  }

  /^\[/ {
    if (in_provider) {
      emit_provider()
      in_provider=0
    }
    if (in_features) {
      emit_image_feature()
      in_features=0
    }

    if ($0 == provider_section) {
      in_provider=1
      print
      next
    }
    if ($0 == "[features]") {
      features_seen=1
      in_features=1
      print
      next
    }
  }

  in_provider && /^[[:space:]]*(name|base_url|wire_api|requires_openai_auth|env_key|http_headers|auth|experimental_bearer_token)[[:space:]]*=/ {
    next
  }

  in_features && /^[[:space:]]*image_generation[[:space:]]*=/ {
    next
  }

  { print }

  END {
    if (in_provider) {
      emit_provider()
    }
    if (in_features) {
      emit_image_feature()
    } else if (!features_seen) {
      print ""
      print "[features]"
      emit_image_feature()
    }
  }
' "$config_file" > "$config_tmp"

chmod "$config_mode" "$config_tmp"
mv "$config_tmp" "$config_file"
trap - EXIT HUP INT TERM

mkdir -p "$codex_home/bin" "$HOME/Library/LaunchAgents"

cat > "$env_helper" <<EOF
#!/bin/sh
set -eu
auth_file='$auth_file'
key="\$(/usr/bin/plutil -extract OPENAI_API_KEY raw -- "\$auth_file" 2>/dev/null || true)"
if [ -z "\$key" ]; then
  exit 0
fi
/bin/launchctl setenv OPENAI_API_KEY "\$key"
key=''
unset key
EOF
chmod 700 "$env_helper"

cat > "$launch_agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$launch_agent_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$env_helper</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
</dict>
</plist>
EOF
chmod 600 "$launch_agent"

"$env_helper"
user_id="$(id -u)"
/bin/launchctl bootout "gui/$user_id/$launch_agent_label" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$user_id" "$launch_agent"
/bin/launchctl kickstart -k "gui/$user_id/$launch_agent_label"

if [ -n "$(/bin/launchctl getenv OPENAI_API_KEY 2>/dev/null)" ]; then
  echo 'OPENAI_API_KEY(macOS user launchd)=EXISTS'
else
  echo 'ERROR: OPENAI_API_KEY(macOS user launchd)=MISSING' >&2
  exit 1
fi

provider_ok="$(awk -v section="$provider_section" '
  $0 == section { in_provider=1; next }
  /^\[/ { in_provider=0 }
  in_provider && /^[[:space:]]*env_key[[:space:]]*=[[:space:]]*"OPENAI_API_KEY"/ { env_key=1 }
  in_provider && /^[[:space:]]*requires_openai_auth[[:space:]]*=[[:space:]]*false/ { openai_auth=1 }
  in_provider && /x-openai-actor-authorization/ && /local-relay/ { actor_header=1 }
  in_provider && /^[[:space:]]*(auth|experimental_bearer_token)[[:space:]]*=/ { legacy_auth=1 }
  END { print (env_key && openai_auth && actor_header && !legacy_auth) ? "true" : "false" }
' "$config_file")"

if [ "$provider_ok" != 'true' ]; then
  echo 'ERROR: Provider configuration validation failed.' >&2
  exit 1
fi
echo 'provider_config=OK'

if [ ! -x "$native_codex" ]; then
  echo "ERROR: Missing native Codex binary: $native_codex" >&2
  exit 1
fi

OPENAI_API_KEY="$relay_key" "$native_codex" features list >/dev/null 2>&1
echo "codex_version=$($native_codex --version 2>/dev/null)"

models_file="$(mktemp)"
responses_file="$(mktemp)"
cleanup_api_files() {
  if [ -f "$models_file" ]; then unlink "$models_file"; fi
  if [ -f "$responses_file" ]; then unlink "$responses_file"; fi
}
trap cleanup_api_files EXIT HUP INT TERM

models_status="$(printf 'Authorization: Bearer %s\n' "$relay_key" | curl -sS --retry 2 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 90 -o "$models_file" -w '%{http_code}' -H @- "$relay_base_url/models")"
echo "models_http=$models_status"

if command -v jq >/dev/null 2>&1; then
  if jq -e '.data[]? | select(.id == "gpt-image-2")' "$models_file" >/dev/null 2>&1; then
    echo 'gpt-image-2=AVAILABLE'
  else
    echo 'ERROR: gpt-image-2=UNAVAILABLE' >&2
    exit 1
  fi
  if jq -e '.data[]? | select(.id == "gpt-5.4")' "$models_file" >/dev/null 2>&1; then
    echo 'gpt-5.4=AVAILABLE'
  else
    echo 'ERROR: gpt-5.4=UNAVAILABLE' >&2
    exit 1
  fi
fi

responses_status="$(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$relay_key" | curl -sS --retry 2 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 90 -o "$responses_file" -w '%{http_code}' -H @- --data-binary '{"model":"gpt-5.4","input":"Reply with OK.","max_output_tokens":16}' "$relay_base_url/responses")"
echo "responses_http=$responses_status"
case "$responses_status" in
  2??) ;;
  *) echo 'ERROR: Responses validation failed.' >&2; exit 1 ;;
esac

for old_helper in "$codex_home/custom-provider-auth.cjs" "$(dirname "$0")/custom-provider-auth.cjs"; do
  if [ -f "$old_helper" ] && ! grep -Fq 'custom-provider-auth.cjs' "$config_file"; then
    unlink "$old_helper"
    echo "removed_unused_helper=$old_helper"
  fi
done

relay_key=''
unset relay_key

echo 'image_generation_config=READY'
echo 'Restart Codex completely, including background processes, then create a new task.'
echo 'Use a tool-capable chat model such as gpt-5.4; built-in image_gen will generate with gpt-image-2.'
