# Minecraft D Edition account service

This Cloudflare Worker hosts the account website and its server-side API. Auth0 handles authentication, while D1 stores profiles, opaque sessions, and validated PNG skins.

## Security model

- Passwords are entered only on Auth0 Universal Login and never reach MCDE.
- OAuth uses authorization code flow with PKCE, state, and nonce.
- Browser sessions are random opaque values; only SHA-256 hashes are stored in D1.
- Session cookies are `HttpOnly`, `Secure`, and `SameSite=Lax`.
- Profile changes require a same-origin request and a per-session CSRF token.
- Skin files must have a PNG signature and a 64×64 IHDR and must be at most 256 KB.
- Auth0 access tokens are discarded after the profile is fetched.
- Password changes use Auth0's one-time email reset flow; passwords never pass through MCDE.
- Account deletion uses a separate least-privilege Auth0 client with only `delete:users`.

## Initial provisioning

1. Run `npm install`.
2. Authenticate Wrangler with `npx wrangler login`.
3. Create D1 database `minecraft-d-edition-accounts` and place its ID in `wrangler.jsonc`.
4. Apply the D1 migration remotely.
5. Set `AUTH0_CLIENT_SECRET`, `AUTH0_MANAGEMENT_CLIENT_ID`, `AUTH0_MANAGEMENT_CLIENT_SECRET`, and a random 32-byte-or-longer `SESSION_SECRET` with `wrangler secret put`.
6. Set the Auth0 tenant domain and client ID in `wrangler.jsonc`.
7. Deploy with `npm run deploy`.

The Auth0 regular web application must allow:

- Callback URL: `https://account.minecraftdedition.com/callback`
- Logout URL: `https://account.minecraftdedition.com/`
- Web origin: `https://account.minecraftdedition.com`
