# Duke University

Duke's identity team documents SP setup at
<https://authentication.oit.duke.edu/manager/documentation>. That guide is
written for Apache. Use it for registration and attributes, and this toolkit
for the nginx side.

## Install

Copy `examples/duke/.env` to the toolkit folder as `.env`, change `DOMAIN`,
`SP_ENTITY_ID`, `UPSTREAM`, `PROTECTED_PATHS` and the email addresses, then run:

```bash
sudo ./install.sh --yes
```

Or run `sudo ./install.sh` and answer `duke` when it asks for the IdP metadata
URL. The preset fills in:

| Setting | Value |
|---|---|
| Metadata | `https://shib.oit.duke.edu/duke-metadata-3-signed.xml` |
| Signing certificate | `https://shib.oit.duke.edu/idp_signing.crt` |
| IdP entityID | `https://shib.oit.duke.edu/shibboleth-idp` (read from the metadata) |

## Register

1. Register the SP at
   <https://authentication.oit.duke.edu/manager/register/sp> with the values
   from `sudo ./install.sh info`: entityID, metadata URL, ACS URL and the contents of
   `/etc/shibboleth/sp-encrypt-cert.pem`.
2. Under **My Sites**, select the attributes your application needs.
3. Register test and production servers separately.

Before registration, a protected path shows Duke's "not registered" page. That
page means the SP itself works.

## Attributes

Duke releases `eppn` (`netid@duke.edu`) by default. Select anything else under
My Sites. The standard attributes (`uid` for the NetID, `mail`, `displayName`,
`affiliation` and others) are already mapped in `templates/attribute-map.xml`.

Duke also offers attributes named with URNs. To use them, add these lines before
`</Attributes>` in `templates/attribute-map.xml`, then add their ids to
`ATTRIBUTES`:

```xml
<Attribute name="urn:mace:duke.edu:idms:unique-id" id="duDukeID"/>
<Attribute name="urn:mace:duke.edu:idms:dku-id" id="dkuID"/>
<Attribute name="urn:mace:duke.edu:idms:middle-name1" id="duMiddleName1"/>
```

Duke's full list is in its documentation under "Available attributes".
