CREATE TABLE desktop_login_requests (
  id TEXT PRIMARY KEY,
  poll_secret_hash TEXT NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  mode TEXT NOT NULL CHECK (mode IN ('login', 'signup')),
  expires_at INTEGER NOT NULL,
  authorized_at INTEGER
);

CREATE INDEX desktop_login_expiry_idx ON desktop_login_requests(expires_at);
