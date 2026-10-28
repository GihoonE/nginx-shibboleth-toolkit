# Verifying and troubleshooting

## Check in this order

`sudo ./install.sh verify` runs steps 1 to 4.

1. **Configuration loads:** `sudo shibd -t` ends with "overall configuration
   is loadable", and `sudo nginx -t` succeeds.
2. **FastCGI programs run:** `sudo supervisorctl status` shows
   `shibauthorizer` and `shibresponder` as `RUNNING`.
3. **The SP answers:** on the server, run
   `curl -sk https://<host>/Shibboleth.sso/Status --resolve <host>:443:127.0.0.1`.
   It should contain `<Status><OK/></Status>`. Status only answers requests from
   the server itself, so a browser elsewhere gets an error by design.
4. **Login redirects:** a protected path answers `302` to the IdP.
5. **IdP knows the SP:** in a private browser window, open a protected path.
   - The IdP login page means the registration is done.
   - "Not registered with our Identity Provider" means the SP side works and
     registration is still pending.
6. **Who signed in:** after login, open `https://<host>/Shibboleth.sso/Session`.
   It shows the IdP, the session and the attribute values for your own session.
7. **The application receives the user:** log the request headers in your
   application, or use the Django example in the README.

Logs:

| Log | Contains |
|---|---|
| `/var/log/shibboleth/shibd.log` | Start here: metadata, signature and decryption errors |
| `/var/log/shibboleth/transaction.log` | One line per login, with the attributes received |
| `/var/log/shibboleth/authorizer.err.log`, `responder.err.log` | FastCGI program errors |
| `/var/log/nginx/error.log` | Module loading, socket and proxy errors |

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| nginx does not start: `module ... is not binary compatible` | nginx was upgraded after the module was built | `sudo ./install.sh module` |
| `unknown directive "shib_request"` | Module not loaded | Check `/etc/nginx/modules-enabled/50-mod-http-shibboleth.conf`, then run `sudo ./install.sh module` |
| `unknown directive "more_clear_input_headers"` | headers-more module missing | `sudo apt install libnginx-mod-http-headers-more-filter` |
| 502 Bad Gateway on a protected path or `/Shibboleth.sso` | FastCGI program down, or nginx cannot open the socket | `sudo supervisorctl status`, `ls -l /run/shibboleth/`. The socket group must be nginx's group |
| "Unable to locate metadata for identity provider" | IdP metadata did not load: wrong URL, failed download or signature check | `shibd.log`. Verify `METADATA_URL` and `METADATA_CERT_URL` |
| `shibd.log`: signature verification failed | The certificate does not sign this metadata | Get the current signing certificate from the identity team |
| IdP: "not registered", or an error naming the ACS URL | SP not registered, or registered with a different entityID or ACS | Register the values from `sudo ./install.sh info` |
| Login loops, or the session expires immediately | Server clock is off, or the session cookie is lost | `timedatectl` should report NTP synchronized. Use HTTPS throughout, because the cookie is HTTPS-only |
| Login works but a header is empty | Attribute not released, not mapped, or not in `ATTRIBUTES` | Compare `/Shibboleth.sso/Session` with [attributes.md](attributes.md) |
| Decryption errors in `shibd.log` | The IdP has an old encryption certificate | Send the current `sp-encrypt-cert.pem` to the identity team. Never regenerate keys without updating the registration |
| A client-sent `eppn` header reaches the app | A location lacks `clear-headers.conf`, or the app is reachable without nginx | Include the snippet in every location and bind the app to `127.0.0.1` |

Institution-specific errors: Duke lists its common errors at
<https://authentication.oit.duke.edu/manager/documentation>.
