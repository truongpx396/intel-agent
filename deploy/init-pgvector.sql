-- Enabled at first boot so the pgvector backend has its type available before
-- migrations run. RLS policies themselves live in migrations/, not here.
CREATE EXTENSION IF NOT EXISTS vector;
