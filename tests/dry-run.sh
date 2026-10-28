#!/usr/bin/env bash
# Renders the configuration with --dry-run and checks the result. No root needed.
# Run: tests/dry-run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=test -days 1 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

cat >"$tmp/.env" <<ENV
DOMAIN=app.test.edu
SP_ENTITY_ID=https://app.test.edu/shibboleth
SITE_MODE=full
UPSTREAM=http://127.0.0.1:9000
PROTECTED_PATHS="/login /api/auth"
METADATA_URL=file://$PWD/tests/fixtures/federation.xml
METADATA_CERT_URL=file://$tmp/cert.pem
IDP_ENTITY_ID=https://login.beta.edu/idp
ATTRIBUTES="eppn displayName subject-id"
TLS_MODE=existing
TLS_CERT=/etc/ssl/app.pem
TLS_KEY=/etc/ssl/app.key
SUPPORT_EMAIL=ops@test.edu
ENV

out=$(./install.sh --env "$tmp/.env" --yes --dry-run 2>&1) || { echo "$out"; fail "dry run exited non-zero"; }
stage=$(sed -n 's/.*rendered files are in //p' <<<"$out")
[[ -d $stage ]] || { echo "$out"; fail "no stage folder"; }
trap 'rm -rf "$tmp" "$(dirname "$stage")"' EXIT

grep -q 'entityID="https://login.beta.edu/idp"' "$stage/shibboleth2.xml" || fail "IdP entityID"
grep -q '<Path name="api/auth" authType="shibboleth" requireSession="true"/>' "$stage/shibboleth2.xml" || fail "request map"
grep -q 'type="Signature"' "$stage/shibboleth2.xml" || fail "signature filter"
grep -q 'location ^~ /api/auth' "$stage/site-https.conf" || fail "protected location"
grep -q 'proxy_pass http://127.0.0.1:9000;' "$stage/site-https.conf" || fail "upstream"
grep -q 'location / {' "$stage/site-https.conf" || fail "default location"
grep -q 'return 301 https://$host$request_uri;' "$stage/site-http.conf" || fail "nginx variables kept"
grep -q 'shib_request_set $shib_subject_id $upstream_http_variable_subject_id;' "$stage/protect.conf" || fail "attribute variable"
grep -q 'proxy_set_header displayName $shib_displayname;' "$stage/protect.conf" || fail "attribute header"
grep -q 'more_clear_input_headers subject-id;' "$stage/clear-headers.conf" || fail "clear header"
grep -q 'unix:/run/shibboleth-fastcgi/shibauthorizer.sock' "$stage/handlers.conf" || fail "socket"
! grep -n '\${' "$stage"/*.conf "$stage/shibboleth2.xml" || fail "unreplaced placeholder"

# A federation without IDP_ENTITY_ID must stop instead of guessing.
sed -i.bak '/^IDP_ENTITY_ID=/d' "$tmp/.env"
if ./install.sh --env "$tmp/.env" --yes --dry-run >"$tmp/out" 2>&1; then fail "federation without IDP_ENTITY_ID"; fi
grep -q 'lists 2 identity providers' "$tmp/out" || { cat "$tmp/out"; fail "federation message"; }

echo "dry run: all checks passed"
