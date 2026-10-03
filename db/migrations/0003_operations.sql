-- Idempotency ledger: rewards and trades are keyed by a caller-supplied
-- op_id; a replayed op returns its recorded result instead of re-applying.

CREATE TABLE IF NOT EXISTS operations (
    op_id      text PRIMARY KEY CHECK (length(op_id) BETWEEN 1 AND 64),
    kind       text NOT NULL,
    result     jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS operations_kind_idx ON operations (kind);
