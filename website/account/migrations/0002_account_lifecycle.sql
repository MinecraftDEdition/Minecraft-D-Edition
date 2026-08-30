ALTER TABLE accounts ADD COLUMN account_status TEXT NOT NULL DEFAULT 'active'
  CHECK (account_status IN ('active', 'inactive'));
ALTER TABLE accounts ADD COLUMN deactivated_at INTEGER;
ALTER TABLE accounts ADD COLUMN last_password_reset_at INTEGER;

CREATE INDEX accounts_status_idx ON accounts(account_status);
