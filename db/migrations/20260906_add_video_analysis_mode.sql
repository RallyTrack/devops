-- Existing rows remain NULL because their original upload mode cannot be reconstructed.
ALTER TABLE videos
    ADD COLUMN IF NOT EXISTS analysis_mode VARCHAR(16) NULL
    CHECK (analysis_mode IN ('pro', 'amateur'));
