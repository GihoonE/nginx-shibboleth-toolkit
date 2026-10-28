# Attributes

An IdP sends user information as SAML attributes named by OIDs. Shibboleth maps
each OID to a short id in `attribute-map.xml`. nginx then passes each id listed
in `ATTRIBUTES` to your application as a request header with the same name.

## Getting an attribute to your application

1. **Request it from the IdP.** The IdP releases only the attributes it agreed
   to release for your SP. How you ask depends on the institution (see
   [idp-registration.md](idp-registration.md)).
2. **Map it** in `templates/attribute-map.xml`. The standard attributes below
   are already mapped.
3. **List its id** in `ATTRIBUTES` in `.env`, then rerun `sudo ./install.sh`.
   This also adds the id to the list of headers that clients may not send.

If an attribute is missing, check these steps in order. Opening
`/Shibboleth.sso/Session` after login shows which attributes actually arrived.

## Standard attributes

These come from the eduPerson and inetOrgPerson schemas, so most institutions
use the same OIDs. Which ones an institution releases, and to whom, varies.

| id | OID | Value |
|---|---|---|
| `subject-id` | `urn:oasis:names:tc:SAML:attribute:subject-id` | Stable, scoped user identifier (newer standard) |
| `pairwise-id` | `urn:oasis:names:tc:SAML:attribute:pairwise-id` | Like subject-id, but different for each SP |
| `eppn` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.6` | eduPersonPrincipalName, scoped: `netid@example.edu` |
| `uid` | `urn:oid:0.9.2342.19200300.100.1.1` | Login name without scope |
| `persistent-id` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.10` | Opaque, per-SP identifier |
| `affiliation` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.9` | eduPersonScopedAffiliation: `student@example.edu` |
| `unscoped-affiliation` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.1` | eduPersonAffiliation: `student`, `faculty`, `staff`, … |
| `primary-affiliation` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.5` | One main role |
| `entitlement` | `urn:oid:1.3.6.1.4.1.5923.1.1.1.7` | Rights granted by the institution |
| `isMemberOf` | `urn:oid:1.3.6.1.4.1.5923.1.5.1.1` | Group memberships |
| `displayName` | `urn:oid:2.16.840.1.113730.3.1.241` | Preferred full name |
| `cn` | `urn:oid:2.5.4.3` | Common name |
| `givenName` | `urn:oid:2.5.4.42` | First name |
| `sn` | `urn:oid:2.5.4.4` | Surname |
| `mail` | `urn:oid:0.9.2342.19200300.100.1.3` | Email address |

## Choosing a user identifier

Pick the identifier first, because changing it later means migrating user
records.

- Prefer **`subject-id`** or **`eppn`**. They are scoped, so they stay unique
  when users come from more than one institution.
- **`uid`** is convenient but unscoped, and some institutions never release it.
- **`pairwise-id`** and **`persistent-id`** reveal nothing about the user, but
  you cannot match them with records from other systems.

## Institution-specific attributes

Institutions add their own attributes, often named with a URN instead of an
OID. Add a mapping at the end of `templates/attribute-map.xml`:

```xml
<Attribute name="urn:mace:example.edu:employee-number" id="employeeNumber"/>
```

Scoped values need `<AttributeDecoder xsi:type="ScopedAttributeDecoder"/>`
inside the element. Use the attribute names that your identity team documents.
The Duke attributes are in [examples/duke/README.md](../examples/duke/README.md).

## Header names

Header names keep the attribute id. Most frameworks convert them, so `eppn`
becomes `HTTP_EPPN` in Django and `displayName` becomes `HTTP_DISPLAYNAME`.
Avoid underscores in ids: nginx drops headers that contain underscores, and so
does gunicorn.
