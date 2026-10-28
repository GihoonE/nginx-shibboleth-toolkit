#!/usr/bin/env bash
# nginx-shibboleth-toolkit: protect nginx locations with a Shibboleth SP.
# Run as root on Debian or Ubuntu. See README.md.
set -euo pipefail

TOOLKIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATES=$TOOLKIT_DIR/templates
MODULE_REPO=https://github.com/nginx-shib/nginx-http-shibboleth.git
MODULE_REF=${MODULE_REF:-v2.0.2}
MODULE_SO=/usr/lib/nginx/modules/ngx_http_shibboleth_module.so
SHIB_DIR=/etc/shibboleth
SNIPPETS=/etc/nginx/snippets/shibboleth
ACME_ROOT=/var/www/letsencrypt
# Created at boot by the shibboleth-sp-utils tmpfiles entry; shibd restarts keep it.
SOCKET_DIR=/run/shibboleth
BACKUP_DIR=/var/backups/nginx-shibboleth-toolkit/$(date +%Y%m%d-%H%M%S)

CMD=install
ENV_FILE=$TOOLKIT_DIR/.env
YES=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [command] [options]

Commands:
  install   Ask for settings, then install and configure everything (default)
  module    Rebuild the nginx Shibboleth module (run after an nginx upgrade)
  verify    Check that shibd, the FastCGI sockets and nginx work
  info      Print the values to register with your identity provider

Options:
  --env FILE   Settings file (default: .env next to this script)
  --yes        Do not ask anything; take every value from the settings file
  --dry-run    Render the configuration into a temporary folder and stop
  -h, --help   Show this help
EOF
}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ask VAR "prompt" [default]: keep a value that the settings file already set.
ask() {
    local _var=$1 _prompt=$2 _def=${3-} _reply
    [[ -n ${!_var-} ]] && return 0
    if (( YES )); then
        [[ -n $_def ]] || die "$_var is not set in $ENV_FILE"
        printf -v "$_var" %s "$_def"
        return 0
    fi
    while :; do
        read -rp "$_prompt${_def:+ [$_def]}: " _reply
        _reply=${_reply:-$_def}
        [[ -n $_reply ]] && break
        echo "  A value is required."
    done
    printf -v "$_var" %s "$_reply"
}

confirm() {
    (( YES )) && return 0
    local answer
    read -rp "$1 [y/N]: " answer
    [[ $answer == [yY]* ]]
}

# ask_choice VAR "prompt" default choice...: like ask, but asks again on a wrong answer.
ask_choice() {
    local _var=$1 _prompt=$2 _def=$3 _choice
    shift 3
    while :; do
        ask "$_var" "$_prompt ($*)" "$_def"
        for _choice in "$@"; do [[ ${!_var} == "$_choice" ]] && return 0; done
        (( YES )) && die "$_var='${!_var}' is not one of: $*"
        echo "  Choose one of: $*"
        printf -v "$_var" %s ""
    done
}

# --- Settings -----------------------------------------------------------------

apply_preset() {
    case $1 in
        duke)
            METADATA_URL=https://shib.oit.duke.edu/duke-metadata-3-signed.xml
            METADATA_CERT_URL=${METADATA_CERT_URL:-https://shib.oit.duke.edu/idp_signing.crt}
            REGISTRATION_URL=${REGISTRATION_URL:-https://authentication.oit.duke.edu/manager/register/sp}
            ;;
        *) return 1 ;;
    esac
}

# Prints "entityID<TAB>display name" for every IdP in a SAML metadata file.
list_idps() {
    python3 -I - "$1" <<'EOF'
import sys
import xml.etree.ElementTree as ET

MD = "{urn:oasis:names:tc:SAML:2.0:metadata}"
MDUI = "{urn:oasis:names:tc:SAML:metadata:ui}"
try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as e:
    sys.exit(f"metadata is not valid XML: {e}")
entities = [root] if root.tag == MD + "EntityDescriptor" else root.iter(MD + "EntityDescriptor")
for e in entities:
    idp = e.find(MD + "IDPSSODescriptor")
    if idp is None:
        continue
    # Element truthiness counts children, so compare with None explicitly.
    name = idp.find(f".//{MDUI}DisplayName")
    if name is None:
        name = e.find(f"{MD}Organization/{MD}OrganizationDisplayName")
    label = " ".join((name.text or "").split()) if name is not None else ""
    print(f"{e.get('entityID')}\t{label}")
EOF
}

choose_idp() {
    local file=$1 idps count
    idps=$(list_idps "$file") || die "could not read the IdP metadata"
    count=$(grep -c . <<<"$idps" || true)
    (( count > 0 )) || die "the metadata at $METADATA_URL lists no identity provider"
    if [[ -n ${IDP_ENTITY_ID-} ]]; then
        cut -f1 <<<"$idps" | grep -qxF "$IDP_ENTITY_ID" \
            || die "IDP_ENTITY_ID $IDP_ENTITY_ID is not in the metadata"
        return 0
    fi
    if (( count == 1 )); then
        IDP_ENTITY_ID=$(cut -f1 <<<"$idps")
        ok "Identity provider: $IDP_ENTITY_ID"
        return 0
    fi
    (( YES )) && die "the metadata lists $count identity providers; set IDP_ENTITY_ID in $ENV_FILE"
    echo "The metadata lists $count identity providers (a federation). Search for yours."
    local term matches pick
    while :; do
        read -rp "Institution name or domain: " term
        matches=$(grep -iF -- "$term" <<<"$idps" | head -20 || true)
        [[ -n $matches ]] || { echo "  No match."; continue; }
        nl -w2 -s') ' <<<"$matches" | tr '\t' ' '
        read -rp "Number (Enter to search again): " pick
        [[ $pick =~ ^[0-9]+$ ]] || continue
        IDP_ENTITY_ID=$(sed -n "${pick}p" <<<"$matches" | cut -f1)
        [[ -n $IDP_ENTITY_ID ]] && break
    done
    ok "Identity provider: $IDP_ENTITY_ID"
}

fetch_idp() {
    WORK_METADATA=$WORK/idp-metadata.xml
    log "Downloading IdP metadata"
    curl -fsSL --max-time 60 "$METADATA_URL" -o "$WORK_METADATA" \
        || die "could not download $METADATA_URL"
    choose_idp "$WORK_METADATA"

    WORK_CERT=
    if [[ -n ${METADATA_CERT_URL-} ]]; then
        WORK_CERT=$WORK/idp-metadata-signing.crt
        curl -fsSL --max-time 60 "$METADATA_CERT_URL" -o "$WORK_CERT" \
            || die "could not download $METADATA_CERT_URL"
        local fp
        fp=$(openssl x509 -in "$WORK_CERT" -noout -fingerprint -sha256 2>/dev/null) \
            || die "$METADATA_CERT_URL is not a PEM certificate"
        ok "Metadata signing certificate ${fp#*=}"
        echo "     Compare this fingerprint with the one your institution publishes."
    elif [[ ${ALLOW_UNSIGNED_METADATA-} != yes ]]; then
        warn "No metadata signing certificate: shibd cannot tell genuine metadata from a forged copy."
        (( YES )) && die "set METADATA_CERT_URL, or ALLOW_UNSIGNED_METADATA=yes to accept this"
        confirm "Continue without verifying the metadata signature?" || die "stopped"
        ALLOW_UNSIGNED_METADATA=yes
    fi
}

collect_settings() {
    if [[ -f $ENV_FILE ]]; then
        if (( YES )) || confirm "Use the saved settings in $ENV_FILE?"; then
            # shellcheck disable=SC1090
            source "$ENV_FILE"
        fi
    elif (( YES )); then
        die "$ENV_FILE does not exist; copy .env.example or an examples/ file there"
    fi

    ask DOMAIN "Public host name of this server" "$(hostname -f 2>/dev/null || hostname)"
    ask SP_ENTITY_ID "SP entityID (changing it later means registering again)" "https://$DOMAIN/shibboleth"
    ask_choice SITE_MODE "nginx: write a whole site, or only snippets for your own server block" full full snippets
    if [[ $SITE_MODE == full ]]; then
        ask UPSTREAM "Application behind nginx" http://127.0.0.1:8000
    fi
    ask PROTECTED_PATHS "Paths that need a login (space separated)" /secure

    if [[ -z ${METADATA_URL-} ]]; then
        local idp_input=
        ask idp_input "IdP metadata URL, or a preset name (duke)"
        apply_preset "$idp_input" || METADATA_URL=$idp_input
    fi
    if [[ -z ${METADATA_CERT_URL-} && ${ALLOW_UNSIGNED_METADATA-} != yes ]] && (( !YES )); then
        read -rp "URL of the IdP metadata signing certificate (Enter if none): " METADATA_CERT_URL
    fi
    fetch_idp

    ask ATTRIBUTES "Attributes to pass to the application" "eppn uid mail displayName affiliation"

    if [[ $SITE_MODE == full ]]; then
        ask_choice TLS_MODE "TLS certificate" letsencrypt letsencrypt existing
        if [[ $TLS_MODE == letsencrypt ]]; then
            ask LETSENCRYPT_EMAIL "Email for Let's Encrypt expiry notices"
            TLS_CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
            TLS_KEY=/etc/letsencrypt/live/$DOMAIN/privkey.pem
        else
            ask TLS_CERT "Certificate (full chain) path"
            ask TLS_KEY "Private key path"
        fi
    fi
    ask SUPPORT_EMAIL "Contact shown on Shibboleth error pages" "${LETSENCRYPT_EMAIL:-root@localhost}"
}

save_settings() {
    local var
    {
        echo "# Written by install.sh on $(date -u +%Y-%m-%dT%H:%MZ). Edit and rerun to change."
        for var in DOMAIN SP_ENTITY_ID SITE_MODE UPSTREAM PROTECTED_PATHS METADATA_URL \
            METADATA_CERT_URL ALLOW_UNSIGNED_METADATA IDP_ENTITY_ID REGISTRATION_URL ATTRIBUTES \
            TLS_MODE LETSENCRYPT_EMAIL TLS_CERT TLS_KEY SUPPORT_EMAIL; do
            [[ -n ${!var-} ]] && printf '%s=%q\n' "$var" "${!var}"
        done
    } >"$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# --- Rendering ----------------------------------------------------------------

shib_libexec() {
    local found
    found=$(ls -d /usr/lib/*/shibboleth 2>/dev/null | head -1 || true)
    echo "${found:-/usr/lib/$(uname -m)-linux-gnu/shibboleth}"
}

nginx_user() {
    local user
    user=$(sed -n 's/^[[:space:]]*user[[:space:]]\{1,\}\([^[:space:];]*\).*/\1/p' /etc/nginx/nginx.conf 2>/dev/null | head -1)
    echo "${user:-www-data}"
}

render() {
    # envsubst only replaces the listed variables, so nginx's own $variables survive.
    envsubst '${DOMAIN} ${SP_ENTITY_ID} ${IDP_ENTITY_ID} ${METADATA_URL} ${METADATA_FILTER}
        ${REQUEST_MAP_HOST} ${SUPPORT_EMAIL} ${SHIB_LIBEXEC} ${NGINX_GROUP} ${SOCKET_DIR} ${UPSTREAM}
        ${TLS_CERT} ${TLS_KEY} ${ACME_ROOT} ${PROTECTED_LOCATIONS} ${DEFAULT_LOCATION}
        ${CLEAR_HEADERS} ${SHIB_REQUEST_SETS}' <"$TEMPLATES/$1" >"$STAGE/$2"
}

render_all() {
    STAGE=$WORK/stage
    mkdir -p "$STAGE"
    export DOMAIN SP_ENTITY_ID IDP_ENTITY_ID METADATA_URL SUPPORT_EMAIL ACME_ROOT
    export UPSTREAM=${UPSTREAM-} TLS_CERT=${TLS_CERT-} TLS_KEY=${TLS_KEY-}
    export SHIB_LIBEXEC NGINX_GROUP SOCKET_DIR
    SHIB_LIBEXEC=$(shib_libexec)
    NGINX_GROUP=$(id -gn "$(nginx_user)" 2>/dev/null || echo www-data)

    export METADATA_FILTER=
    [[ -n ${WORK_CERT-} ]] && METADATA_FILTER='<MetadataFilter type="Signature" certificate="idp-metadata-signing.crt"/>'

    local path attr var
    export REQUEST_MAP_HOST= PROTECTED_LOCATIONS= DEFAULT_LOCATION= CLEAR_HEADERS= SHIB_REQUEST_SETS=
    for path in $PROTECTED_PATHS; do
        [[ $path == /* ]] || die "protected path '$path' must start with /"
        REQUEST_MAP_HOST+="                <Path name=\"${path#/}\" authType=\"shibboleth\" requireSession=\"true\"/>"$'\n'
        PROTECTED_LOCATIONS+="    location ^~ $path {
        include snippets/shibboleth/clear-headers.conf;
        include snippets/shibboleth/protect.conf;
        include snippets/shibboleth/proxy-headers.conf;
        proxy_pass $UPSTREAM;
    }

"
    done
    if [[ " $PROTECTED_PATHS " == *" / "* ]]; then
        # The whole host needs a login, so the setting goes on <Host> itself.
        REQUEST_MAP_HOST="<Host name=\"$DOMAIN\" authType=\"shibboleth\" requireSession=\"true\" redirectToSSL=\"443\"/>"
    else
        REQUEST_MAP_HOST="<Host name=\"$DOMAIN\" redirectToSSL=\"443\">
${REQUEST_MAP_HOST}            </Host>"
        DEFAULT_LOCATION="    location / {
        include snippets/shibboleth/clear-headers.conf;
        include snippets/shibboleth/proxy-headers.conf;
        proxy_pass $UPSTREAM;
    }"
    fi

    CLEAR_HEADERS="more_clear_input_headers Auth-Type Remote-User Shib-Application-ID Shib-Authentication-Instant
    Shib-Authentication-Method Shib-AuthnContext-Class Shib-AuthnContext-Decl Shib-Identity-Provider
    Shib-Session-ID Shib-Session-Index;"
    SHIB_REQUEST_SETS="shib_request_set \$shib_remote_user \$upstream_http_variable_remote_user;
proxy_set_header Remote-User \$shib_remote_user;
"
    for attr in $ATTRIBUTES; do
        var=$(lower "$attr" | tr -c 'a-z0-9\n' _)
        CLEAR_HEADERS+=$'\n'"more_clear_input_headers $attr;"
        SHIB_REQUEST_SETS+="shib_request_set \$shib_$var \$upstream_http_variable_$var;
proxy_set_header $attr \$shib_$var;
"
    done

    render shibboleth2.xml shibboleth2.xml
    cp "$TEMPLATES/attribute-map.xml" "$STAGE/attribute-map.xml"
    render supervisor-shibboleth.conf supervisor-shibboleth.conf
    render nginx/handlers.conf handlers.conf
    render nginx/clear-headers.conf clear-headers.conf
    render nginx/protect.conf protect.conf
    cp "$TEMPLATES/nginx/fastcgi-params.conf" "$TEMPLATES/nginx/proxy-headers.conf" "$STAGE/"
    if [[ $SITE_MODE == full ]]; then
        render nginx/site-http.conf site-http.conf
        render nginx/site-https.conf site-https.conf
    fi
    python3 -I -c 'import sys, xml.dom.minidom as m; [m.parse(f) for f in sys.argv[1:]]' \
        "$STAGE/shibboleth2.xml" "$STAGE/attribute-map.xml" || die "rendered XML is not well formed"
}

# --- Installation steps -------------------------------------------------------

# put SRC DEST MODE [OWNER]: install a file, backing up a different existing one.
put() {
    local src=$1 dest=$2 mode=$3 owner=${4:-root:root}
    if [[ -f $dest ]] && ! cmp -s "$src" "$dest"; then
        mkdir -p "$BACKUP_DIR$(dirname "$dest")"
        cp -a "$dest" "$BACKUP_DIR$dest"
    fi
    install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dest"
}

install_packages() {
    log "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    local pkgs=(nginx libnginx-mod-http-headers-more-filter shibboleth-sp-utils supervisor
        build-essential git curl ca-certificates openssl gettext-base python3)
    [[ ${TLS_MODE-} == letsencrypt ]] && pkgs+=(certbot)
    apt-get install -y -qq "${pkgs[@]}" >/dev/null
    # nginx-dev ships the build files of the distribution's nginx. It is missing
    # when nginx comes from nginx.org; build_module then downloads the source.
    apt-get install -y -qq nginx-dev >/dev/null 2>&1 || warn "nginx-dev is not available; the module will be built from nginx.org source"
    ok "Packages installed"
}

build_module() {
    local version stamp src
    version=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    [[ -n $version ]] || die "could not read the nginx version"
    stamp="nginx $version, module $MODULE_REF"
    if [[ $CMD != module && -f $MODULE_SO && "$(cat "$MODULE_SO.build" 2>/dev/null)" == "$stamp" ]]; then
        ok "Shibboleth module already built for nginx $version"
        return 0
    fi
    log "Building the Shibboleth module for nginx $version"
    # A dynamic module only loads into the exact nginx version it was built for.
    nginx -V 2>&1 | grep -q -- --with-compat \
        || die "this nginx was built without --with-compat; build nginx with the module statically instead"

    local build=$WORK/build
    mkdir -p "$build"
    if [[ -x /usr/share/nginx/src/configure ]] && dpkg-query -W -f='${Version}' nginx-dev 2>/dev/null | grep -q "^$version"; then
        cp -a /usr/share/nginx/src "$build/nginx"
        ok "Using the nginx-dev sources"
    else
        curl -fsSL "https://nginx.org/download/nginx-$version.tar.gz" | tar -xz -C "$build" \
            || die "could not download nginx $version source"
        mv "$build/nginx-$version" "$build/nginx"
        ok "Using nginx.org source for $version"
    fi
    git clone -q --depth 1 --branch "$MODULE_REF" "$MODULE_REPO" "$build/module" 2>/dev/null \
        || die "could not clone $MODULE_REPO at $MODULE_REF"
    # The nginx-dev tree has no top-level Makefile, so call objs/Makefile directly.
    if ! (cd "$build/nginx" && ./configure --with-compat --add-dynamic-module=../module \
        && make -f objs/Makefile -j"$(nproc)" modules) >"$build/build.log" 2>&1; then
        tail -n 30 "$build/build.log" >&2
        die "module build failed (full log: $build/build.log)"
    fi
    put "$build/nginx/objs/ngx_http_shibboleth_module.so" "$MODULE_SO" 0644
    echo "$stamp" >"$MODULE_SO.build"
    echo 'load_module modules/ngx_http_shibboleth_module.so;' >/etc/nginx/modules-enabled/50-mod-http-shibboleth.conf
    ok "Module installed: $MODULE_SO"
}

make_sp_keys() {
    local use
    for use in signing encrypt; do
        if [[ -f $SHIB_DIR/sp-$use-key.pem ]]; then
            ok "SP $use key already exists (kept, so the IdP registration stays valid)"
            continue
        fi
        shib-keygen -u _shibd -g _shibd -h "$DOMAIN" -e "$SP_ENTITY_ID" -y 10 -o "$SHIB_DIR" -n "sp-$use" >/dev/null 2>&1
        [[ -f $SHIB_DIR/sp-$use-key.pem && -f $SHIB_DIR/sp-$use-cert.pem ]] \
            || die "shib-keygen did not write $SHIB_DIR/sp-$use-{key,cert}.pem"
        chmod 600 "$SHIB_DIR/sp-$use-key.pem"
        ok "Generated $SHIB_DIR/sp-$use-key.pem"
    done
}

configure_shibboleth() {
    log "Configuring the Shibboleth SP"
    make_sp_keys
    put "$STAGE/shibboleth2.xml" "$SHIB_DIR/shibboleth2.xml" 0644
    put "$STAGE/attribute-map.xml" "$SHIB_DIR/attribute-map.xml" 0644
    if [[ -n ${WORK_CERT-} ]]; then
        put "$WORK_CERT" "$SHIB_DIR/idp-metadata-signing.crt" 0644
    fi
    shibd -t >"$WORK/shibd-t.log" 2>&1 || { cat "$WORK/shibd-t.log" >&2; die "shibd rejected the configuration"; }
    systemctl enable -q shibd
    systemctl restart shibd
    ok "shibd restarted"
}

configure_supervisor() {
    log "Starting the FastCGI authorizer and responder"
    [[ -x $SHIB_LIBEXEC/shibauthorizer ]] || die "$SHIB_LIBEXEC/shibauthorizer is missing; this shibboleth-sp-utils was built without FastCGI"
    put "$STAGE/supervisor-shibboleth.conf" /etc/supervisor/conf.d/shibboleth.conf 0644
    systemctl enable -q --now supervisor
    # A freshly started supervisord needs a moment before supervisorctl can connect.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        supervisorctl status >/dev/null 2>&1 && break
        [[ $? == 3 ]] && break  # exit 3: connected, but some program is not running
        sleep 1
    done
    supervisorctl reread >/dev/null
    supervisorctl update >/dev/null
    supervisorctl restart 'shibauthorizer:*' 'shibresponder:*' >/dev/null
    ok "shibauthorizer and shibresponder running"
}

install_site() {
    local site=/etc/nginx/sites-available/shibboleth-$DOMAIN.conf
    if [[ -f $TLS_CERT && -f $TLS_KEY ]]; then
        cat "$STAGE/site-http.conf" "$STAGE/site-https.conf" >"$WORK/site.conf"
    else
        cp "$STAGE/site-http.conf" "$WORK/site.conf"
    fi
    put "$WORK/site.conf" "$site" 0644
    ln -sf "$site" /etc/nginx/sites-enabled/
}

reload_nginx() {
    nginx -t >"$WORK/nginx-t.log" 2>&1 || { cat "$WORK/nginx-t.log" >&2; die "nginx rejected the configuration (backups: $BACKUP_DIR)"; }
    systemctl enable -q nginx
    systemctl reload-or-restart nginx
}

configure_nginx() {
    log "Configuring nginx"
    local f
    for f in fastcgi-params handlers clear-headers protect proxy-headers; do
        put "$STAGE/$f.conf" "$SNIPPETS/$f.conf" 0644
    done
    if [[ $SITE_MODE == full ]]; then
        if [[ $TLS_MODE == existing && ! ( -f $TLS_CERT && -f $TLS_KEY ) ]]; then
            die "TLS_CERT or TLS_KEY does not exist"
        fi
        mkdir -p "$ACME_ROOT"
        install_site
    fi
    reload_nginx
    ok "nginx reloaded"
}

obtain_certificate() {
    [[ ${TLS_MODE-} == letsencrypt ]] || return 0
    if [[ -f $TLS_CERT ]]; then
        ok "Let's Encrypt certificate already present"
        return 0
    fi
    log "Requesting a Let's Encrypt certificate for $DOMAIN"
    local args=(certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" -m "$LETSENCRYPT_EMAIL"
        --deploy-hook "systemctl reload nginx")
    if (( YES )); then
        [[ ${LETSENCRYPT_AGREE_TOS-} == yes ]] || die "set LETSENCRYPT_AGREE_TOS=yes after reading https://letsencrypt.org/repository/"
        args+=(--non-interactive --agree-tos)
    fi
    certbot "${args[@]}" || die "certbot failed; check that $DOMAIN resolves to this server and port 80 is open"
    install_site
    reload_nginx
    ok "HTTPS enabled"
}

# --- Checks and output --------------------------------------------------------

preflight() {
    [[ $(id -u) == 0 ]] || die "run as root (sudo ./install.sh)"
    command -v apt-get >/dev/null || die "this installer supports Debian and Ubuntu (apt) only"
    . /etc/os-release
    log "Server: $PRETTY_NAME, $(uname -m)"
    case "$ID ${VERSION_ID-}" in
        "debian 12" | "debian 13" | "ubuntu 22.04" | "ubuntu 24.04") ;;
        *) warn "$PRETTY_NAME is untested; continuing" ;;
    esac
    # The settings step needs these before the main package install.
    local tool missing=()
    for tool in curl:curl openssl:openssl python3:python3 envsubst:gettext-base; do
        command -v "${tool%%:*}" >/dev/null || missing+=("${tool#*:}")
    done
    if (( ${#missing[@]} )); then
        log "Installing helper tools: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates >/dev/null
    fi
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
        warn "the clock is not NTP-synchronized; SAML logins fail when it drifts by minutes"
    fi
}

check_dns() {
    local resolved
    resolved=$(getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')
    [[ -n $resolved ]] || { warn "$DOMAIN does not resolve yet"; return 0; }
    local ip
    for ip in $resolved; do
        ip -o addr show 2>/dev/null | grep -qF " $ip/" && return 0
    done
    warn "$DOMAIN resolves to $resolved, which is not an address of this server (fine behind NAT or a load balancer)"
}

show_plan() {
    cat <<EOF

Settings
  Host            $DOMAIN
  SP entityID     $SP_ENTITY_ID
  IdP             $IDP_ENTITY_ID
  IdP metadata    $METADATA_URL ${WORK_CERT:+(signature checked)}
  Protected paths $PROTECTED_PATHS
  Attributes      $ATTRIBUTES
  nginx           $SITE_MODE${UPSTREAM:+, proxying to $UPSTREAM}${TLS_MODE:+, TLS: $TLS_MODE}

Changes
  - apt packages: nginx, headers-more, shibboleth-sp-utils, supervisor, build tools
  - build $MODULE_SO ($MODULE_REF) unless it already matches this nginx
  - $SHIB_DIR: SP keys (only if missing), shibboleth2.xml, attribute-map.xml
  - /etc/supervisor/conf.d/shibboleth.conf
  - $SNIPPETS/*.conf$([[ $SITE_MODE == full ]] && echo ", /etc/nginx/sites-available/shibboleth-$DOMAIN.conf")
  Files that change are first copied to $BACKUP_DIR.

EOF
}

print_info() {
    local where=${REGISTRATION_URL:-"ask your institution's identity or SSO team (see docs/idp-registration.md)"}
    cat <<EOF

Register this service provider with your identity provider
  entityID           $SP_ENTITY_ID
  Metadata URL       https://$DOMAIN/Shibboleth.sso/Metadata
  ACS URL (POST)     https://$DOMAIN/Shibboleth.sso/SAML2/POST
  Encryption cert    $SHIB_DIR/sp-encrypt-cert.pem  (not the website's TLS certificate)
  Attributes needed  $ATTRIBUTES
  Where to register  $where

After registration, open https://$DOMAIN${PROTECTED_PATHS%% *} in a private window,
sign in, then open https://$DOMAIN/Shibboleth.sso/Session to see who is signed in
and which attributes arrived.
EOF
}

verify() {
    log "Verifying"
    local failed=0
    if shibd -t >/dev/null 2>&1; then ok "shibd -t: configuration loads"; else warn "shibd -t failed; run it to see why"; failed=1; fi
    if nginx -t >/dev/null 2>&1; then ok "nginx -t: configuration is valid"; else warn "nginx -t failed"; failed=1; fi
    local p
    for p in shibauthorizer shibresponder; do
        if supervisorctl status "$p:*" 2>/dev/null | grep -q RUNNING; then ok "$p running"; else warn "$p is not running (supervisorctl status)"; failed=1; fi
    done

    local scheme=https status
    [[ ${SITE_MODE-} == full && ! -f ${TLS_CERT-} ]] && scheme=http
    status=$(curl -sk --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" --resolve "$DOMAIN:80:127.0.0.1" \
        "$scheme://$DOMAIN/Shibboleth.sso/Status" || true)
    if grep -q '<OK/>' <<<"$status"; then
        ok "/Shibboleth.sso/Status reports OK"
    else
        warn "/Shibboleth.sso/Status did not report OK (see docs/troubleshooting.md)"
        failed=1
    fi

    local first=${PROTECTED_PATHS%% *} result
    result=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' \
        --resolve "$DOMAIN:443:127.0.0.1" --resolve "$DOMAIN:80:127.0.0.1" "$scheme://$DOMAIN$first" || true)
    if [[ $result == 302\ * ]]; then
        ok "$first redirects to the IdP: ${result#302 }"
    else
        warn "$first did not redirect to the IdP (got: $result)"
        failed=1
    fi
    if grep -E ' (ERROR|CRIT) ' /var/log/shibboleth/shibd.log 2>/dev/null | tail -n 5 | grep .; then
        warn "recent errors in /var/log/shibboleth/shibd.log (above)"
    fi
    return "$failed"
}

# --- Main ---------------------------------------------------------------------

while (( $# )); do
    case $1 in
        install | module | verify | info) CMD=$1 ;;
        --env) ENV_FILE=$2; shift ;;
        --yes) YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

WORK=$(mktemp -d)
(( DRY_RUN )) || trap 'rm -rf "$WORK"' EXIT

case $CMD in
    module)
        preflight
        build_module
        reload_nginx
        ;;
    verify | info)
        [[ -f $ENV_FILE ]] || die "$ENV_FILE does not exist; run install first"
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        if [[ $CMD == verify ]]; then verify; else print_info; fi
        ;;
    install)
        (( DRY_RUN )) || preflight
        collect_settings
        render_all
        show_plan
        if (( DRY_RUN )); then
            log "Dry run: rendered files are in $STAGE"
            exit 0
        fi
        check_dns
        confirm "Apply these changes?" || die "stopped; nothing was changed"
        save_settings
        install_packages
        build_module
        configure_shibboleth
        configure_supervisor
        configure_nginx
        obtain_certificate
        verify || warn "some checks failed; see docs/troubleshooting.md"
        print_info
        ;;
esac
