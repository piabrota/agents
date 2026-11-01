# shellcheck shell=bash
# Tokens for the GitHub App piabrota-ops, as marola-dev/marola-devkit's bot-token action mints them
# (marola's MIP-0086): one hour, one named repository, only the permissions asked for. The App's
# key never leaves this process; the token is all a request carries.

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# github_app_jwt: the App's own JWT (RS256, ten minutes), from GH_APP_ID and the private key in
# GH_APP_PRIVATE_KEY_B64 (the .pem file, base64 on one line, as an env file needs it).
github_app_jwt() {
  need GH_APP_ID GH_APP_PRIVATE_KEY_B64
  local key now header payload sig
  key=$(mktemp)
  printf '%s' "$GH_APP_PRIVATE_KEY_B64" | base64 -d >"$key"
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  # Issued a minute in the past, for clock drift (GitHub's docs).
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$GH_APP_ID" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url)
  rm -f "$key"
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# github_app_token OWNER/REPO PERMISSIONS_JSON: an installation token for that repository alone,
# with those permissions alone. Both are required: GitHub would otherwise mint for every
# repository the App is installed on, with every permission it has.
github_app_token() {
  local repo=$1 perms=$2 jwt installation
  if [ -z "$repo" ] || [ -z "$perms" ] || [ "$perms" = "{}" ]; then
    die "github_app_token: name the repository and the permissions"
  fi
  jwt=$(github_app_jwt)
  installation=$(curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    "$GITHUB_API/repos/$repo/installation" | jq -er .id) ||
    die "${BOT_LOGIN%\[bot\]} is not installed on $repo"
  jq -n --arg r "${repo#*/}" --argjson p "$perms" '{repositories: [$r], permissions: $p}' |
    curl -fsS -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
      --data-binary @- "$GITHUB_API/app/installations/$installation/access_tokens" |
    jq -er .token
}
