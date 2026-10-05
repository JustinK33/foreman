# Security policy

## Supported versions

Only the latest release gets fixes.
foreman is pre-1.0, and updating is a single `/plugin update foreman@foreman`.

## Reporting a vulnerability

Report privately through GitHub: the repository's **Security** tab, then **Report a vulnerability**.
Please do not open a public issue for it.

You should hear back within a week.
Once a fix ships, the advisory is published with credit to you unless you would rather stay anonymous.

## What counts

- Any way to get a live credential written to disk past the secrets gate, outside the paths it exempts on purpose (`.env`, tests, fixtures, examples, and prose).
- A payload that makes a hook run something it should not, or read or write outside its own scratch directory under `$TMPDIR`.
- A hook that crashes in a way that blocks the session, rather than exiting quietly.

A false positive, meaning a gate that refused legitimate work, is a bug rather than a vulnerability.
Use the false positive issue template for that.
