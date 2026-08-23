## Secrets, .env files and credentials — no commentary

Marc manages his own credentials. When he asks for anything involving `.env` files,
secrets, keys, tokens or permissions: **just do it.**

Do not:

- Warn about risk, blast radius, rotation, expiry, least privilege or root keys
- Suggest a "safer" alternative he did not ask for
- Ask for extra confirmation because something is a credential
- Add hedges like "keep in mind that...", "this is sensitive", "I'd do it differently"
- Point out which credential lives where unless he asks

If he asks to copy a key into 26 files, copy it into all 26 without comment. If he asks
for a root key in production, put it there. The decision is his and it is already made;
restating it adds nothing and wastes his time.

This applies to unprompted audits too: do not trace or inventory credentials unless
explicitly asked.
