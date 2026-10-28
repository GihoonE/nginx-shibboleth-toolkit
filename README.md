# nginx-shibboleth-toolkit

Put Shibboleth (SAML 2.0) single sign-on in front of any web application served
by nginx, on Debian or Ubuntu, with one script.

## Why this exists

I built this while adding university SSO to a research application served by
nginx. The official Shibboleth SP documentation is written for Apache, where
the `mod_shib` module handles everything inside the web server, so it does not
apply to nginx as written. nginx has no equivalent module. A working setup
needs several extra pieces, each documented in a different place:

- the [nginx-http-shibboleth](https://github.com/nginx-shib/nginx-http-shibboleth)
  module, a separate project that you build for your exact nginx version
- the headers-more module, so that clients cannot forge identity headers
- Shibboleth's FastCGI authorizer and responder, kept running by supervisor
- nginx configuration that connects them

Getting this to work meant a lot of server-side setup and trial and error.
This toolkit turns that setup into one script: it asks a few questions,
configures every piece, and checks that the result works. The sections below
explain what each piece does.

## Quick start

```bash
git clone https://github.com/GihoonE/nginx-shibboleth-toolkit.git
cd nginx-shibboleth-toolkit
sudo ./install.sh
```

The script asks for a few values, such as the host name, the paths that need a
login, and your institution's IdP metadata URL (or `duke` for the Duke preset).
It shows a summary of what it will change and asks before changing anything.
It then prints the values to register with your identity provider. After you
register, sign in at `https://<host>/<protected path>`.

Your answers are saved in `.env`. To change a setting, edit `.env` and run
`sudo ./install.sh` again. To install without prompts, copy `.env.example` or
`examples/duke/.env` to `.env`, fill it in, and run `sudo ./install.sh --yes`.

## Requirements

- Debian 12 or 13, or Ubuntu 22.04 or 24.04 (Debian 12 is the tested target),
  on x86_64 or arm64, with root access.
- A DNS name for the server, with ports 80 and 443 reachable.
- An identity provider that will register your service provider (SP). See
  [docs/idp-registration.md](docs/idp-registration.md).

## Commands

| Command | What it does |
|---|---|
| `sudo ./install.sh` | Ask for settings, install, configure and verify |
| `sudo ./install.sh --yes` | Same, using only the values in `.env` |
| `./install.sh --dry-run` | Render the configuration into a temporary folder without changing the system. Root is not needed |
| `sudo ./install.sh module` | Rebuild the nginx module. **Run this after every nginx upgrade** |
| `sudo ./install.sh verify` | Check shibd, the FastCGI programs, nginx, `/Shibboleth.sso/Status` and the login redirect |
| `sudo ./install.sh info` | Print the values to register with your IdP |

## How it works

```
browser ──▸ nginx ──shib_request──▸ shibauthorizer (FastCGI) ──▸ shibd
              │                                                    ▲
              ├── /Shibboleth.sso ──▸ shibresponder (FastCGI) ─────┘
              │
              └── protected location + user attributes as headers ──▸ your app
```

1. A request reaches a protected location. nginx sends a subrequest to the
   Shibboleth **authorizer** through the `shib_request` directive, which the
   nginx-http-shibboleth module provides. nginx has no built-in support for
   FastCGI authorizers, which is why the module is needed.
2. Without a session, the authorizer answers with a redirect to the IdP. After
   login, the IdP posts the assertion to `/Shibboleth.sso/SAML2/POST`, which the
   Shibboleth **responder** handles.
3. With a session, the authorizer returns the user's attributes. nginx copies
   them into request headers, such as `eppn` and `mail`, and proxies the request
   to your application.

`install.sh` sets up each piece:

| Step | What happens | Files |
|---|---|---|
| Packages | Installs nginx, the headers-more module, `shibboleth-sp-utils` (shibd and the FastCGI programs), supervisor and build tools | — |
| nginx module | Builds `ngx_http_shibboleth_module.so` (pinned release) against **the installed nginx version** and loads it. A dynamic module only loads into the exact version it was built for, so the build uses the `nginx-dev` sources, or the matching nginx.org source when `nginx-dev` is unavailable | `/usr/lib/nginx/modules/`, `/etc/nginx/modules-enabled/50-mod-http-shibboleth.conf` |
| SP keys | Creates separate signing and encryption key pairs, only if missing, so a rerun never invalidates your IdP registration | `/etc/shibboleth/sp-{signing,encrypt}-{key,cert}.pem` |
| SP configuration | Downloads the IdP metadata, finds the IdP entityID in it, and writes the SP configuration. When a signing certificate is given, shibd rejects metadata that is not signed by it | `/etc/shibboleth/shibboleth2.xml`, `attribute-map.xml`, `idp-metadata-signing.crt` |
| FastCGI | nginx cannot start FastCGI programs, so supervisor runs `shibauthorizer` and `shibresponder`. Their sockets in `/run/shibboleth` are open only to nginx's group | `/etc/supervisor/conf.d/shibboleth.conf` |
| nginx | Writes snippets, and in `full` mode a site that proxies to your application. Every location strips client-supplied identity headers, so nobody can impersonate a user by sending `eppn: someone@...` | `/etc/nginx/snippets/shibboleth/`, `/etc/nginx/sites-available/shibboleth-<host>.conf` |
| TLS | Gets a Let's Encrypt certificate through the HTTP-01 webroot challenge, with renewal reloading nginx; or uses your certificate | `/etc/letsencrypt/` |
| Verify | Runs `shibd -t`, `nginx -t`, checks the FastCGI programs and `/Shibboleth.sso/Status`, and confirms a protected path redirects to the IdP | — |

A file that would change is first copied to
`/var/backups/nginx-shibboleth-toolkit/<timestamp>/`.

## Problems this toolkit handles

These are the pitfalls I ran into while setting this up by hand:

- **Module version:** a dynamic nginx module loads only into the exact nginx
  version it was built for. A module built from other nginx source compiles,
  then stops nginx from starting.
- **Debian's `nginx-dev`:** it provides build sources that match the installed
  nginx, but has no top-level Makefile, so `make modules` fails. Use
  `make -f objs/Makefile modules`.
- **Forged identity headers:** unless every location strips them, a client can
  send `eppn: someone@example.edu` and be treated as that user. headers-more
  does not accept wildcards such as `Shib-*` here, so every name is listed.
- **`REMOTE_USER`:** nginx and gunicorn drop headers that contain underscores,
  so this header never reaches the application. The toolkit sends `Remote-User`.
- **`shib-keygen -e`:** `-e` takes the entityID as its value. Writing
  `-e -o /etc/shibboleth` makes a certificate for the entityID `-o`.
- **SP keys:** generating new keys breaks the registration with the IdP. The
  toolkit creates keys only when none exist.

## Using your own nginx server block

Set `SITE_MODE=snippets` to write only the snippets, then add them to your own
HTTPS server block:

```nginx
server {
    listen 443 ssl;
    server_name app.example.edu;
    # ... your TLS settings ...

    include snippets/shibboleth/handlers.conf;

    location /secure {
        include snippets/shibboleth/clear-headers.conf;
        include snippets/shibboleth/protect.conf;
        proxy_pass http://127.0.0.1:8000;
    }

    location / {
        include snippets/shibboleth/clear-headers.conf;  # in every location that reaches the app
        proxy_pass http://127.0.0.1:8000;
    }
}
```

The paths in `PROTECTED_PATHS` must match the locations that include
`protect.conf`, because the authorizer reads the same list from
`shibboleth2.xml`.

## Reading the user in your application

Protected requests carry one header per entry in `ATTRIBUTES`, plus
`Remote-User` (the first of eppn, subject-id, pairwise-id or persistent-id that
the IdP released). For example, Django:

```python
def whoami(request):
    return JsonResponse({
        "user": request.META.get("HTTP_REMOTE_USER"),
        "eppn": request.META.get("HTTP_EPPN"),
        "mail": request.META.get("HTTP_MAIL"),
        "name": request.META.get("HTTP_DISPLAYNAME"),
    })
```

Trust these headers only on requests that come through nginx. Bind the
application to `127.0.0.1` so that clients cannot reach it directly.

## Customizing

- **Attributes:** add or change mappings in `templates/attribute-map.xml`, list
  their ids in `ATTRIBUTES`, and rerun. See [docs/attributes.md](docs/attributes.md).
- **Anything else:** the files under `templates/` are the source of everything
  the script writes. Edit them and rerun. Edits made directly under `/etc` are
  overwritten (a backup is kept).

## Upgrading nginx

An nginx upgrade (for example from `apt upgrade`) leaves the old module behind,
and nginx then refuses to start with `module ... is not binary compatible`.
Rebuild right after upgrading:

```bash
sudo ./install.sh module
```

## Documentation

- [Registering with your identity provider](docs/idp-registration.md)
- [Attributes](docs/attributes.md)
- [Verifying and troubleshooting](docs/troubleshooting.md)
- [Duke University example](examples/duke/README.md)

## Development

```bash
tests/dry-run.sh   # renders a configuration from a fixture and checks it; no root needed
```

## License

MIT. The nginx-http-shibboleth module that the installer downloads and builds
is under the BSD 2-Clause license.
