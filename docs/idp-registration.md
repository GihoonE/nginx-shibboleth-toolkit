# Registering with your identity provider

Logins work only after your institution's identity provider (IdP) knows your
service provider (SP). Until then, the IdP shows an error such as "The
application you have accessed is not registered". If you see that error, the
SP side is already set up correctly.

## What every IdP needs

`sudo ./install.sh info` prints these values:

| Value | Example | Notes |
|---|---|---|
| entityID | `https://app.example.edu/shibboleth` | Your SP's unique name. Changing it later means registering again |
| Metadata URL | `https://app.example.edu/Shibboleth.sso/Metadata` | Most IdP teams accept this URL or the file it returns. It contains everything else in this table |
| Assertion Consumer Service (ACS) | `https://app.example.edu/Shibboleth.sso/SAML2/POST` | Where the IdP posts the login result |
| Encryption certificate | `/etc/shibboleth/sp-encrypt-cert.pem` | Lets the IdP encrypt assertions for you. This is **not** your website's TLS certificate |
| Attributes | `eppn mail displayName` | The user information your application needs (see [attributes.md](attributes.md)) |

The process differs by institution:

- **Self-service portal:** some institutions, such as Duke, let you register
  the SP and pick attributes on a web page.
- **Ticket or email:** many identity teams register SPs by request. Send the
  metadata URL, the attributes you need and why, and a contact.
- **Test and production:** register each environment separately. Each one has
  its own host name and entityID.

Ask your institution's IT or identity team where to start. Searching the IT
site for "Shibboleth", "SAML" or "SSO service provider" usually finds the page.

## What you need from the IdP

| Value | Setting | Notes |
|---|---|---|
| IdP metadata URL | `METADATA_URL` | The installer reads the IdP entityID from it |
| Metadata signing certificate | `METADATA_CERT_URL` | Lets shibd reject forged metadata. If none is published, compare the fingerprint the installer prints with one obtained from the identity team |
| IdP entityID | `IDP_ENTITY_ID` | Needed only for federation metadata that lists many IdPs |
| Test account | — | Some institutions issue guest accounts for testing |

## Federations

Federations such as InCommon or eduGAIN publish one metadata file that lists
every member IdP. When `METADATA_URL` points to such a file, the installer asks
you to search for your institution, or reads `IDP_ENTITY_ID` with `--yes`.

This toolkit configures one IdP. Letting users choose among several IdPs needs
a discovery service and changes to the `<SSO>` element in
`templates/shibboleth2.xml`; see the Shibboleth SP documentation. Large
aggregates also make shibd slow to start; the federation's MDQ service is the
lighter option.

## Duke University

See [examples/duke/README.md](../examples/duke/README.md).
