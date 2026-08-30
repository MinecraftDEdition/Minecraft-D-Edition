interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  SITE_ORIGIN: string;
  AUTH0_DOMAIN: string;
  AUTH0_CLIENT_ID: string;
  AUTH0_CLIENT_SECRET: string;
  SESSION_SECRET: string;
}

interface AccountRow {
  id: string;
  auth0_sub: string;
  email: string;
  email_verified: number;
  username: string | null;
  has_skin: number;
  skin_model: 'classic' | 'slim';
  created_at: number;
  updated_at: number;
}

interface SessionRow extends AccountRow {
  csrf_token: string;
  expires_at: number;
}

interface OAuthState {
  state: string;
  nonce: string;
  verifier: string;
  expiresAt: number;
}

const encoder = new TextEncoder();
const SESSION_SECONDS = 60 * 60 * 24 * 7;
const OAUTH_SECONDS = 60 * 10;
const MAX_SKIN_BYTES = 256 * 1024;
const USERNAME = /^[A-Za-z0-9_]{3,16}$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname === '/login' && request.method === 'GET') return beginLogin(env);
      if (url.pathname === '/callback' && request.method === 'GET') return finishLogin(request, env);
      if (url.pathname === '/logout' && request.method === 'POST') return logout(request, env);
      if (url.pathname === '/api/me' && request.method === 'GET') return getMe(request, env);
      if (url.pathname === '/api/profile' && request.method === 'POST') return updateProfile(request, env);
      if (url.pathname === '/api/skin' && request.method === 'POST') return updateSkin(request, env);
      if (url.pathname.startsWith('/skins/') && request.method === 'GET') return getSkin(url, env);
      if (url.pathname.startsWith('/api/')) return json({ error: 'Not found.' }, 404);

      const asset = await env.ASSETS.fetch(request);
      return withSecurityHeaders(asset);
    } catch (error) {
      console.error('Unhandled account service error', error);
      return json({ error: 'The account service hit an unexpected error.' }, 500);
    }
  }
} satisfies ExportedHandler<Env>;

async function beginLogin(env: Env): Promise<Response> {
  assertConfigured(env);
  const state: OAuthState = {
    state: randomToken(24),
    nonce: randomToken(24),
    verifier: randomToken(48),
    expiresAt: Date.now() + OAUTH_SECONDS * 1000
  };
  const challenge = base64Url(await crypto.subtle.digest('SHA-256', encoder.encode(state.verifier)));
  const cookie = await signValue(JSON.stringify(state), env.SESSION_SECRET);
  const authorize = new URL(`https://${env.AUTH0_DOMAIN}/authorize`);
  authorize.searchParams.set('response_type', 'code');
  authorize.searchParams.set('client_id', env.AUTH0_CLIENT_ID);
  authorize.searchParams.set('redirect_uri', `${env.SITE_ORIGIN}/callback`);
  authorize.searchParams.set('scope', 'openid profile email');
  authorize.searchParams.set('state', state.state);
  authorize.searchParams.set('nonce', state.nonce);
  authorize.searchParams.set('code_challenge', challenge);
  authorize.searchParams.set('code_challenge_method', 'S256');

  return new Response(null, {
    status: 302,
    headers: {
      Location: authorize.toString(),
      'Set-Cookie': cookieHeader('mcde_oauth', cookie, OAUTH_SECONDS),
      ...securityHeaders()
    }
  });
}

async function finishLogin(request: Request, env: Env): Promise<Response> {
  assertConfigured(env);
  const url = new URL(request.url);
  const error = url.searchParams.get('error');
  if (error) return redirectWithError(env, 'Sign-in was cancelled or could not be completed.');

  const code = url.searchParams.get('code');
  const returnedState = url.searchParams.get('state');
  const signed = readCookie(request, 'mcde_oauth');
  if (!code || !returnedState || !signed) return redirectWithError(env, 'The sign-in response was incomplete.');

  const raw = await verifyValue(signed, env.SESSION_SECRET);
  if (!raw) return redirectWithError(env, 'The sign-in attempt could not be verified.');
  let oauth: OAuthState;
  try {
    oauth = JSON.parse(raw) as OAuthState;
  } catch {
    return redirectWithError(env, 'The sign-in attempt was invalid.');
  }
  if (oauth.expiresAt < Date.now() || !timingSafeEqual(oauth.state, returnedState)) {
    return redirectWithError(env, 'The sign-in attempt expired. Please try again.');
  }

  const tokenResponse = await fetch(`https://${env.AUTH0_DOMAIN}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'authorization_code',
      client_id: env.AUTH0_CLIENT_ID,
      client_secret: env.AUTH0_CLIENT_SECRET,
      code,
      code_verifier: oauth.verifier,
      redirect_uri: `${env.SITE_ORIGIN}/callback`
    })
  });
  if (!tokenResponse.ok) {
    console.error('Auth0 token exchange failed', tokenResponse.status);
    return redirectWithError(env, 'The account provider rejected the sign-in response.');
  }
  const token = await tokenResponse.json<{ access_token?: string }>();
  if (!token.access_token) return redirectWithError(env, 'The account provider did not return an access token.');

  const userResponse = await fetch(`https://${env.AUTH0_DOMAIN}/userinfo`, {
    headers: { Authorization: `Bearer ${token.access_token}` }
  });
  if (!userResponse.ok) return redirectWithError(env, 'Your account profile could not be loaded.');
  const identity = await userResponse.json<{ sub?: string; email?: string; email_verified?: boolean }>();
  if (!identity.sub || !identity.email) return redirectWithError(env, 'Your account is missing a verified identity.');

  const now = Date.now();
  let account = await env.DB.prepare('SELECT * FROM accounts WHERE auth0_sub = ?')
    .bind(identity.sub).first<AccountRow>();
  if (!account) {
    const id = crypto.randomUUID();
    await env.DB.prepare(`INSERT INTO accounts
      (id, auth0_sub, email, email_verified, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)`)
      .bind(id, identity.sub, identity.email, identity.email_verified ? 1 : 0, now, now).run();
    account = await env.DB.prepare('SELECT * FROM accounts WHERE id = ?').bind(id).first<AccountRow>();
  } else {
    await env.DB.prepare('UPDATE accounts SET email = ?, email_verified = ?, updated_at = ? WHERE id = ?')
      .bind(identity.email, identity.email_verified ? 1 : 0, now, account.id).run();
  }
  if (!account) throw new Error('Account creation did not return a record.');

  await env.DB.prepare('DELETE FROM sessions WHERE expires_at <= ?').bind(now).run();
  const sessionToken = randomToken(48);
  const sessionHash = await sha256Hex(sessionToken);
  const csrf = randomToken(24);
  await env.DB.prepare(`INSERT INTO sessions
    (token_hash, account_id, csrf_token, expires_at, created_at) VALUES (?, ?, ?, ?, ?)`)
    .bind(sessionHash, account.id, csrf, now + SESSION_SECONDS * 1000, now).run();

  const headers = new Headers({ Location: `${env.SITE_ORIGIN}/`, ...securityHeaders() });
  headers.append('Set-Cookie', expireCookie('mcde_oauth'));
  headers.append('Set-Cookie', cookieHeader('mcde_session', sessionToken, SESSION_SECONDS));
  return new Response(null, { status: 302, headers });
}

async function getMe(request: Request, env: Env): Promise<Response> {
  const session = await requireSession(request, env);
  if (!session) return json({ authenticated: false }, 401);
  return json({
    authenticated: true,
    account: {
      id: session.id,
      email: session.email,
      emailVerified: Boolean(session.email_verified),
      username: session.username,
      skinUrl: session.has_skin ? `/skins/${session.id}.png?v=${session.updated_at}` : null,
      skinModel: session.skin_model,
      createdAt: session.created_at
    },
    csrfToken: session.csrf_token
  });
}

async function updateProfile(request: Request, env: Env): Promise<Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  let body: { username?: unknown };
  try {
    body = await request.json<{ username?: unknown }>();
  } catch {
    return json({ error: 'Send a valid JSON request.' }, 400);
  }
  const username = typeof body.username === 'string' ? body.username.trim() : '';
  if (!USERNAME.test(username)) {
    return json({ error: 'Usernames must be 3–16 characters using only letters, numbers, and underscores.' }, 400);
  }
  try {
    await env.DB.prepare('UPDATE accounts SET username = ?, username_normalized = ?, updated_at = ? WHERE id = ?')
      .bind(username, username.toLowerCase(), Date.now(), session.id).run();
  } catch (error) {
    if (String(error).toLowerCase().includes('unique')) return json({ error: 'That username is already taken.' }, 409);
    throw error;
  }
  return json({ ok: true, username });
}

async function updateSkin(request: Request, env: Env): Promise<Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  const contentType = request.headers.get('content-type') ?? '';
  if (!contentType.includes('multipart/form-data')) return json({ error: 'Upload a PNG skin file.' }, 400);
  const form = await request.formData();
  const file = form.get('skin');
  const modelValue = form.get('model');
  const model = modelValue === 'slim' ? 'slim' : modelValue === 'classic' ? 'classic' : null;
  if (!(file instanceof File) || !model) return json({ error: 'Choose a PNG skin and a valid model.' }, 400);
  if (file.size > MAX_SKIN_BYTES) return json({ error: 'Skin files must be 256 KB or smaller.' }, 413);
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (!isModernSkinPng(bytes)) return json({ error: 'Skins must be valid 64×64 PNG files.' }, 400);

  const skinBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const now = Date.now();
  await env.DB.prepare('UPDATE accounts SET skin_png = ?, skin_model = ?, updated_at = ? WHERE id = ?')
    .bind(skinBuffer, model, now, session.id).run();
  return json({ ok: true, skinUrl: `/skins/${session.id}.png?v=${now}`, skinModel: model });
}

async function getSkin(url: URL, env: Env): Promise<Response> {
  const match = /^\/skins\/([0-9a-f-]{36})\.png$/i.exec(url.pathname);
  if (!match) return json({ error: 'Skin not found.' }, 404);
  const account = await env.DB.prepare('SELECT skin_png, updated_at FROM accounts WHERE id = ?').bind(match[1])
    .first<{ skin_png: ArrayBuffer | null; updated_at: number }>();
  if (!account?.skin_png) return json({ error: 'Skin not found.' }, 404);
  const headers = new Headers({ 'Content-Type': 'image/png' });
  headers.set('ETag', `"${account.updated_at}"`);
  headers.set('Cache-Control', 'public, max-age=300, stale-while-revalidate=3600');
  Object.entries(securityHeaders()).forEach(([key, value]) => headers.set(key, value));
  return new Response(account.skin_png, { headers });
}

async function logout(request: Request, env: Env): Promise<Response> {
  const token = readCookie(request, 'mcde_session');
  if (token) await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await sha256Hex(token)).run();
  const returnTo = `${env.SITE_ORIGIN}/`;
  const location = new URL(`https://${env.AUTH0_DOMAIN}/v2/logout`);
  location.searchParams.set('client_id', env.AUTH0_CLIENT_ID);
  location.searchParams.set('returnTo', returnTo);
  return new Response(null, {
    status: 302,
    headers: { Location: location.toString(), 'Set-Cookie': expireCookie('mcde_session'), ...securityHeaders() }
  });
}

async function requireSession(request: Request, env: Env): Promise<SessionRow | null> {
  const token = readCookie(request, 'mcde_session');
  if (!token) return null;
  const now = Date.now();
  const session = await env.DB.prepare(`SELECT
      a.id, a.auth0_sub, a.email, a.email_verified, a.username, a.skin_model,
      a.created_at, a.updated_at, CASE WHEN a.skin_png IS NULL THEN 0 ELSE 1 END AS has_skin,
      s.csrf_token, s.expires_at
    FROM sessions s JOIN accounts a ON a.id = s.account_id
    WHERE s.token_hash = ? AND s.expires_at > ?`)
    .bind(await sha256Hex(token), now).first<SessionRow>();
  return session ?? null;
}

async function requireMutatingSession(request: Request, env: Env): Promise<SessionRow | Response> {
  const origin = request.headers.get('Origin');
  if (origin !== env.SITE_ORIGIN) return json({ error: 'This request came from an untrusted origin.' }, 403);
  const session = await requireSession(request, env);
  if (!session) return json({ error: 'Sign in to continue.' }, 401);
  const csrf = request.headers.get('X-CSRF-Token') ?? '';
  if (!timingSafeEqual(csrf, session.csrf_token)) return json({ error: 'The security token was missing or invalid.' }, 403);
  return session;
}

function isModernSkinPng(bytes: Uint8Array): boolean {
  if (bytes.length < 24) return false;
  const png = [137, 80, 78, 71, 13, 10, 26, 10];
  if (!png.every((value, index) => bytes[index] === value)) return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return view.getUint32(16) === 64 && view.getUint32(20) === 64;
}

function assertConfigured(env: Env): void {
  if (env.AUTH0_DOMAIN.startsWith('REPLACE_') || env.AUTH0_CLIENT_ID.startsWith('REPLACE_')) {
    throw new Error('Auth0 is not configured.');
  }
}

function redirectWithError(env: Env, message: string): Response {
  const destination = new URL(env.SITE_ORIGIN);
  destination.searchParams.set('error', message);
  return new Response(null, {
    status: 302,
    headers: { Location: destination.toString(), 'Set-Cookie': expireCookie('mcde_oauth'), ...securityHeaders() }
  });
}

function cookieHeader(name: string, value: string, maxAge: number): string {
  return `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;
}

function expireCookie(name: string): string {
  return `${name}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
}

function readCookie(request: Request, name: string): string | null {
  const cookie = request.headers.get('Cookie') ?? '';
  for (const part of cookie.split(';')) {
    const [key, ...value] = part.trim().split('=');
    if (key === name) return value.join('=');
  }
  return null;
}

async function signValue(value: string, secret: string): Promise<string> {
  const encoded = base64Url(encoder.encode(value));
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(encoded));
  return `${encoded}.${base64Url(signature)}`;
}

async function verifyValue(signed: string, secret: string): Promise<string | null> {
  const [value, signature] = signed.split('.');
  if (!value || !signature) return null;
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const signatureBytes = fromBase64Url(signature);
  const signatureBuffer = signatureBytes.buffer.slice(
    signatureBytes.byteOffset,
    signatureBytes.byteOffset + signatureBytes.byteLength
  ) as ArrayBuffer;
  const valid = await crypto.subtle.verify('HMAC', key, signatureBuffer, encoder.encode(value));
  if (!valid) return null;
  return new TextDecoder().decode(fromBase64Url(value));
}

function randomToken(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64Url(value);
}

function base64Url(value: ArrayBuffer | Uint8Array): string {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function sha256Hex(value: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
  return [...hash].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(left: string, right: string): boolean {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) difference |= (a[index % Math.max(a.length, 1)] ?? 0) ^ (b[index % Math.max(b.length, 1)] ?? 0);
  return difference === 0;
}

function securityHeaders(): Record<string, string> {
  return {
    'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY'
  };
}

function withSecurityHeaders(response: Response): Response {
  const secured = new Response(response.body, response);
  Object.entries(securityHeaders()).forEach(([key, value]) => secured.headers.set(key, value));
  return secured;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      ...securityHeaders()
    }
  });
}
