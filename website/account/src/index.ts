import { d1BlobBytes } from './skin_blob';

interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  SITE_ORIGIN: string;
  AUTH0_DOMAIN: string;
  AUTH0_CLIENT_ID: string;
  AUTH0_CLIENT_SECRET: string;
  AUTH0_MANAGEMENT_CLIENT_ID: string;
  AUTH0_MANAGEMENT_CLIENT_SECRET: string;
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
  account_status: 'active' | 'inactive';
  deactivated_at: number | null;
  last_password_reset_at: number | null;
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
  desktopRequestId?: string;
  desktopMode?: 'login' | 'signup';
}

interface DesktopLoginRow {
  id: string;
  poll_secret_hash: string;
  account_id: string | null;
  mode: 'login' | 'signup';
  expires_at: number;
  authorized_at: number | null;
}

const encoder = new TextEncoder();
const SESSION_SECONDS = 60 * 60 * 24 * 7;
const DESKTOP_SESSION_SECONDS = 60 * 60 * 24 * 30;
const OAUTH_SECONDS = 60 * 10;
const DESKTOP_LOGIN_SECONDS = 60 * 10;
const MAX_SKIN_BYTES = 256 * 1024;
const USERNAME = /^[A-Za-z0-9_]{3,16}$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname === '/login' && request.method === 'GET') return beginLogin(env);
      if (url.pathname === '/desktop/login' && request.method === 'GET') return beginDesktopLogin(request, env, 'login');
      if (url.pathname === '/desktop/signup' && request.method === 'GET') return beginDesktopLogin(request, env, 'signup');
      if (url.pathname === '/callback' && request.method === 'GET') return finishLogin(request, env);
      if (url.pathname === '/logout' && request.method === 'POST') return logout(request, env);
      if (url.pathname === '/api/me' && request.method === 'GET') return getMe(request, env);
      if (url.pathname === '/api/desktop/start' && request.method === 'POST') return startDesktopLogin(request, env);
      if (url.pathname === '/api/desktop/poll' && request.method === 'POST') return pollDesktopLogin(request, env);
      if (url.pathname === '/api/desktop/logout' && request.method === 'POST') return logoutDesktop(request, env);
      if (url.pathname === '/api/profile' && request.method === 'POST') return updateProfile(request, env);
      if (url.pathname === '/api/skin' && request.method === 'POST') return updateSkin(request, env);
      if (url.pathname === '/api/skin' && request.method === 'PUT') return updateDesktopSkin(request, env);
      if (url.pathname === '/api/password/reset' && request.method === 'POST') return requestPasswordReset(request, env);
      if (url.pathname === '/api/account/deactivate' && request.method === 'POST') return deactivateAccount(request, env);
      if (url.pathname === '/api/account/reactivate' && request.method === 'POST') return reactivateAccount(request, env);
      if (url.pathname === '/api/account/delete' && request.method === 'POST') return deleteAccount(request, env);
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
  return beginLoginFlow(env);
}

async function beginDesktopLogin(request: Request, env: Env, mode: 'login' | 'signup'): Promise<Response> {
  const requestId = new URL(request.url).searchParams.get('request') ?? '';
  const pending = await env.DB.prepare(`SELECT id FROM desktop_login_requests
    WHERE id = ? AND mode = ? AND account_id IS NULL AND expires_at > ?`)
    .bind(requestId, mode, Date.now()).first<{ id: string }>();
  if (!pending) return desktopResultPage('This game sign-in request expired. Return to Minecraft: D Edition and try again.', false);
  return beginLoginFlow(env, requestId, mode);
}

async function beginLoginFlow(env: Env, desktopRequestId?: string,
  desktopMode?: 'login' | 'signup'): Promise<Response> {
  assertConfigured(env);
  const state: OAuthState = {
    state: randomToken(24),
    nonce: randomToken(24),
    verifier: randomToken(48),
    expiresAt: Date.now() + OAUTH_SECONDS * 1000,
    desktopRequestId,
    desktopMode
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
  if (desktopMode === 'signup') {
    authorize.searchParams.set('screen_hint', 'signup');
    authorize.searchParams.set('prompt', 'login');
  }

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
  let created = false;
  let account = await env.DB.prepare('SELECT * FROM accounts WHERE auth0_sub = ?')
    .bind(identity.sub).first<AccountRow>();
  if (!account) {
    created = true;
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

  if (oauth.desktopRequestId) {
    const pending = await env.DB.prepare(`SELECT id FROM desktop_login_requests
      WHERE id = ? AND account_id IS NULL AND expires_at > ?`)
      .bind(oauth.desktopRequestId, now).first<{ id: string }>();
    if (!pending) return desktopResultPage('This game sign-in request expired. Return to Minecraft: D Edition and try again.', false);
    await env.DB.prepare(`UPDATE desktop_login_requests
      SET account_id = ?, authorized_at = ? WHERE id = ?`)
      .bind(account.id, now, oauth.desktopRequestId).run();
    const message = created || oauth.desktopMode === 'signup'
      ? "You're good to go! You created an account successfully, and can return to Minecraft: D Edition."
      : "You're good to go! You logged in successfully, and can return to Minecraft: D Edition.";
    const response = desktopResultPage(message, true);
    response.headers.append('Set-Cookie', expireCookie('mcde_oauth'));
    response.headers.append('Set-Cookie', cookieHeader('mcde_session', sessionToken, SESSION_SECONDS));
    return response;
  }

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
      active: session.account_status === 'active',
      deactivatedAt: session.deactivated_at,
      skinUrl: session.has_skin ? `/skins/${session.id}.png?v=${session.updated_at}` : null,
      skinModel: session.skin_model,
      updatedAt: session.updated_at,
      createdAt: session.created_at
    },
    csrfToken: session.csrf_token,
    features: {
      accountDeletion: Boolean(env.AUTH0_MANAGEMENT_CLIENT_ID && env.AUTH0_MANAGEMENT_CLIENT_SECRET)
    }
  });
}

async function startDesktopLogin(request: Request, env: Env): Promise<Response> {
  let mode: 'login' | 'signup' = 'login';
  try {
    const body = await request.json<{ mode?: unknown }>();
    if (body.mode === 'signup') mode = 'signup';
  } catch {
    return json({ error: 'Send a valid login request.' }, 400);
  }
  const now = Date.now();
  await env.DB.prepare('DELETE FROM desktop_login_requests WHERE expires_at <= ?').bind(now).run();
  const id = crypto.randomUUID();
  const pollSecret = randomToken(48);
  await env.DB.prepare(`INSERT INTO desktop_login_requests
    (id, poll_secret_hash, mode, expires_at) VALUES (?, ?, ?, ?)`)
    .bind(id, await sha256Hex(pollSecret), mode, now + DESKTOP_LOGIN_SECONDS * 1000).run();
  return json({
    requestId: id,
    pollSecret,
    authorizeUrl: `${env.SITE_ORIGIN}/desktop/${mode}?request=${encodeURIComponent(id)}`,
    expiresIn: DESKTOP_LOGIN_SECONDS
  });
}

async function pollDesktopLogin(request: Request, env: Env): Promise<Response> {
  let body: { requestId?: unknown; pollSecret?: unknown };
  try {
    body = await request.json<{ requestId?: unknown; pollSecret?: unknown }>();
  } catch {
    return json({ error: 'Send a valid polling request.' }, 400);
  }
  const requestId = typeof body.requestId === 'string' ? body.requestId : '';
  const pollSecret = typeof body.pollSecret === 'string' ? body.pollSecret : '';
  const pending = await env.DB.prepare('SELECT * FROM desktop_login_requests WHERE id = ?')
    .bind(requestId).first<DesktopLoginRow>();
  if (!pending || !pollSecret || !timingSafeEqual(pending.poll_secret_hash, await sha256Hex(pollSecret)))
    return json({ error: 'The game sign-in request is invalid.' }, 404);
  if (pending.expires_at <= Date.now()) {
    await env.DB.prepare('DELETE FROM desktop_login_requests WHERE id = ?').bind(requestId).run();
    return json({ error: 'The game sign-in request expired.' }, 410);
  }
  if (!pending.account_id) return json({ pending: true }, 202);

  const sessionToken = randomToken(48);
  const csrf = randomToken(24);
  const now = Date.now();
  await env.DB.prepare(`INSERT INTO sessions
    (token_hash, account_id, csrf_token, expires_at, created_at) VALUES (?, ?, ?, ?, ?)`)
    .bind(await sha256Hex(sessionToken), pending.account_id, csrf,
      now + DESKTOP_SESSION_SECONDS * 1000, now).run();
  await env.DB.prepare('DELETE FROM desktop_login_requests WHERE id = ?').bind(requestId).run();
  return json({ authenticated: true, token: sessionToken, expiresIn: DESKTOP_SESSION_SECONDS });
}

async function logoutDesktop(request: Request, env: Env): Promise<Response> {
  const token = readBearer(request);
  if (!token) return json({ ok: true });
  await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await sha256Hex(token)).run();
  return json({ ok: true });
}

async function updateProfile(request: Request, env: Env): Promise<Response> {
  const session = await requireActiveMutatingSession(request, env);
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
  const session = await requireActiveMutatingSession(request, env);
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
    .first<{ skin_png: number[] | ArrayBuffer | null; updated_at: number }>();
  if (!account) return json({ error: 'Skin not found.' }, 404);
  const bytes = d1BlobBytes(account.skin_png);
  if (!bytes || !isModernSkinPng(bytes)) return json({ error: 'Skin not found.' }, 404);
  const headers = new Headers({ 'Content-Type': 'image/png' });
  headers.set('ETag', `"${account.updated_at}"`);
  headers.set('Content-Length', String(bytes.byteLength));
  headers.set('Cache-Control', 'public, max-age=300, stale-while-revalidate=3600');
  Object.entries(securityHeaders()).forEach(([key, value]) => headers.set(key, value));
  return new Response(Uint8Array.from(bytes).buffer, { headers });
}

async function logout(request: Request, env: Env): Promise<Response> {
  const token = readCookie(request, 'mcde_session');
  if (token) {
    const tokenHash = await sha256Hex(token);
    const session = await env.DB.prepare('SELECT account_id FROM sessions WHERE token_hash = ?')
      .bind(tokenHash).first<{ account_id: string }>();
    let scope = 'current';
    try {
      const form = await request.formData();
      scope = form.get('scope') === 'all' ? 'all' : 'current';
    } catch {
      // An empty POST still signs out the current session.
    }
    if (scope === 'all' && session) {
      await env.DB.prepare('DELETE FROM sessions WHERE account_id = ?').bind(session.account_id).run();
    } else {
      await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(tokenHash).run();
    }
  }
  const returnTo = `${env.SITE_ORIGIN}/`;
  const location = new URL(`https://${env.AUTH0_DOMAIN}/v2/logout`);
  location.searchParams.set('client_id', env.AUTH0_CLIENT_ID);
  location.searchParams.set('returnTo', returnTo);
  return new Response(null, {
    status: 302,
    headers: { Location: location.toString(), 'Set-Cookie': expireCookie('mcde_session'), ...securityHeaders() }
  });
}

async function updateDesktopSkin(request: Request, env: Env): Promise<Response> {
  const session = await requireActiveMutatingSession(request, env);
  if (session instanceof Response) return session;
  const modelHeader = request.headers.get('X-MCDE-Skin-Model');
  const model = modelHeader === 'slim' ? 'slim' : modelHeader === 'classic' ? 'classic' : null;
  const declaredLength = Number(request.headers.get('Content-Length') ?? 0);
  if (!model) return json({ error: 'Choose a valid player model.' }, 400);
  if (declaredLength > MAX_SKIN_BYTES) return json({ error: "That's not a skin, silly!" }, 413);
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length > MAX_SKIN_BYTES || !isModernSkinPng(bytes))
    return json({ error: "That's not a skin, silly!" }, 400);
  const skinBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const now = Date.now();
  await env.DB.prepare('UPDATE accounts SET skin_png = ?, skin_model = ?, updated_at = ? WHERE id = ?')
    .bind(skinBuffer, model, now, session.id).run();
  return json({ ok: true, skinUrl: `/skins/${session.id}.png?v=${now}`, skinModel: model, updatedAt: now });
}

async function requestPasswordReset(request: Request, env: Env): Promise<Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  if (!session.auth0_sub.startsWith('auth0|')) {
    return json({ error: 'This account signs in through an external provider. Change the password with that provider.' }, 400);
  }
  const now = Date.now();
  if (session.last_password_reset_at && now - session.last_password_reset_at < 60_000) {
    return json({ error: 'A reset email was just requested. Wait one minute before trying again.' }, 429);
  }
  const response = await fetch(`https://${env.AUTH0_DOMAIN}/dbconnections/change_password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: env.AUTH0_CLIENT_ID,
      email: session.email,
      connection: 'Username-Password-Authentication'
    })
  });
  if (!response.ok) {
    console.error('Auth0 password reset request failed', response.status);
    return json({ error: 'The password reset email could not be sent. Please try again later.' }, 502);
  }
  await env.DB.prepare('UPDATE accounts SET last_password_reset_at = ?, updated_at = ? WHERE id = ?')
    .bind(now, now, session.id).run();
  return json({ ok: true, message: 'Check your email for a secure password reset link.' });
}

async function deactivateAccount(request: Request, env: Env): Promise<Response> {
  const session = await requireActiveMutatingSession(request, env);
  if (session instanceof Response) return session;
  const now = Date.now();
  await env.DB.prepare(`UPDATE accounts
    SET account_status = 'inactive', deactivated_at = ?, updated_at = ? WHERE id = ?`)
    .bind(now, now, session.id).run();
  return json({ ok: true, active: false, deactivatedAt: now });
}

async function reactivateAccount(request: Request, env: Env): Promise<Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  if (session.account_status === 'active') return json({ ok: true, active: true });
  const now = Date.now();
  await env.DB.prepare(`UPDATE accounts
    SET account_status = 'active', deactivated_at = NULL, updated_at = ? WHERE id = ?`)
    .bind(now, session.id).run();
  return json({ ok: true, active: true });
}

async function deleteAccount(request: Request, env: Env): Promise<Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  let body: { confirmation?: unknown };
  try {
    body = await request.json<{ confirmation?: unknown }>();
  } catch {
    return json({ error: 'Send a valid deletion confirmation.' }, 400);
  }
  if (body.confirmation !== 'DELETE') {
    return json({ error: 'Type DELETE exactly to permanently delete this account.' }, 400);
  }
  if (!env.AUTH0_MANAGEMENT_CLIENT_ID || !env.AUTH0_MANAGEMENT_CLIENT_SECRET) {
    return json({ error: 'Account deletion is temporarily unavailable.' }, 503);
  }

  const managementToken = await getManagementToken(env);
  if (!managementToken) return json({ error: 'Account deletion is temporarily unavailable.' }, 503);
  const auth0Response = await fetch(`https://${env.AUTH0_DOMAIN}/api/v2/users/${encodeURIComponent(session.auth0_sub)}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${managementToken}` }
  });
  if (!auth0Response.ok && auth0Response.status !== 404) {
    console.error('Auth0 user deletion failed', auth0Response.status);
    return json({ error: 'The identity provider could not delete the account. Nothing was removed.' }, 502);
  }

  await env.DB.prepare('DELETE FROM accounts WHERE id = ?').bind(session.id).run();
  const logout = new URL(`https://${env.AUTH0_DOMAIN}/v2/logout`);
  logout.searchParams.set('client_id', env.AUTH0_CLIENT_ID);
  logout.searchParams.set('returnTo', `${env.SITE_ORIGIN}/?deleted=1`);
  const response = json({ ok: true, logoutUrl: logout.toString() });
  response.headers.append('Set-Cookie', expireCookie('mcde_session'));
  return response;
}

async function getManagementToken(env: Env): Promise<string | null> {
  const response = await fetch(`https://${env.AUTH0_DOMAIN}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: env.AUTH0_MANAGEMENT_CLIENT_ID,
      client_secret: env.AUTH0_MANAGEMENT_CLIENT_SECRET,
      audience: `https://${env.AUTH0_DOMAIN}/api/v2/`
    })
  });
  if (!response.ok) {
    console.error('Auth0 Management API token request failed', response.status);
    return null;
  }
  const body = await response.json<{ access_token?: string }>();
  return body.access_token ?? null;
}

async function requireSession(request: Request, env: Env): Promise<SessionRow | null> {
  const token = readBearer(request) ?? readCookie(request, 'mcde_session');
  if (!token) return null;
  const now = Date.now();
  const session = await env.DB.prepare(`SELECT
      a.id, a.auth0_sub, a.email, a.email_verified, a.username, a.skin_model,
      a.account_status, a.deactivated_at, a.last_password_reset_at,
      a.created_at, a.updated_at, CASE WHEN a.skin_png IS NULL THEN 0 ELSE 1 END AS has_skin,
      s.csrf_token, s.expires_at
    FROM sessions s JOIN accounts a ON a.id = s.account_id
    WHERE s.token_hash = ? AND s.expires_at > ?`)
    .bind(await sha256Hex(token), now).first<SessionRow>();
  return session ?? null;
}

async function requireMutatingSession(request: Request, env: Env): Promise<SessionRow | Response> {
  const bearer = readBearer(request);
  if (bearer) {
    const session = await requireSession(request, env);
    return session ?? json({ error: 'Sign in to continue.' }, 401);
  }
  const origin = request.headers.get('Origin');
  if (origin !== env.SITE_ORIGIN) return json({ error: 'This request came from an untrusted origin.' }, 403);
  const session = await requireSession(request, env);
  if (!session) return json({ error: 'Sign in to continue.' }, 401);
  const csrf = request.headers.get('X-CSRF-Token') ?? '';
  if (!timingSafeEqual(csrf, session.csrf_token)) return json({ error: 'The security token was missing or invalid.' }, 403);
  return session;
}

function readBearer(request: Request): string | null {
  const authorization = request.headers.get('Authorization') ?? '';
  const match = /^Bearer ([A-Za-z0-9_-]{32,})$/.exec(authorization);
  return match?.[1] ?? null;
}

function desktopResultPage(message: string, success: boolean): Response {
  const safeMessage = message.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${success ? 'Account connected' : 'Sign-in problem'} — Minecraft: D Edition</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#fff;font:20px system-ui,sans-serif}.box{max-width:680px;margin:24px;padding:42px;background:#252525;border:3px solid #777;box-shadow:0 8px 0 #000}h1{margin-top:0;color:${success ? '#7cdb62' : '#ff7373'}}p{line-height:1.55}</style></head><body><main class="box"><h1>${success ? 'Account connected' : 'Unable to connect account'}</h1><p>${safeMessage}</p></main></body></html>`;
  const headers = securityHeaders();
  headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'";
  return new Response(html, { status: success ? 200 : 400, headers: { 'Content-Type': 'text/html; charset=utf-8', ...headers } });
}

async function requireActiveMutatingSession(request: Request, env: Env): Promise<SessionRow | Response> {
  const session = await requireMutatingSession(request, env);
  if (session instanceof Response) return session;
  if (session.account_status !== 'active') return json({ error: 'Reactivate this account before changing its profile.' }, 403);
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
