CREATE TABLE documents (
    id TEXT PRIMARY KEY NOT NULL,
    metadata BLOB NOT NULL,
    history_cursor INTEGER NOT NULL DEFAULT 0 CHECK(history_cursor >= 0)
);
CREATE TABLE assets (
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    hash TEXT NOT NULL CHECK(length(hash) = 64),
    ordinal INTEGER NOT NULL,
    metadata BLOB NOT NULL,
    PRIMARY KEY(document_id, hash)
);
CREATE TABLE asset_derivatives (
    document_id TEXT NOT NULL,
    asset_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    metadata BLOB NOT NULL,
    PRIMARY KEY(document_id, asset_hash, role),
    FOREIGN KEY(document_id, asset_hash) REFERENCES assets(document_id, hash) ON DELETE CASCADE
);
CREATE TABLE blocks (
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    parent_id TEXT,
    anchor_id TEXT,
    asset_hash TEXT,
    ordinal INTEGER NOT NULL,
    metadata BLOB NOT NULL,
    PRIMARY KEY(document_id, id),
    FOREIGN KEY(document_id, parent_id) REFERENCES blocks(document_id, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(document_id, anchor_id) REFERENCES blocks(document_id, id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(document_id, asset_hash) REFERENCES assets(document_id, hash) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX blocks_parent ON blocks(document_id, parent_id);
CREATE TABLE text_contents (
    document_id TEXT NOT NULL,
    block_id TEXT NOT NULL,
    content BLOB NOT NULL,
    PRIMARY KEY(document_id, block_id),
    FOREIGN KEY(document_id, block_id) REFERENCES blocks(document_id, id) ON DELETE CASCADE
);
CREATE TABLE block_relations (
    document_id TEXT NOT NULL,
    id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    metadata BLOB NOT NULL,
    PRIMARY KEY(document_id, id),
    FOREIGN KEY(document_id, source_id) REFERENCES blocks(document_id, id) ON DELETE CASCADE,
    FOREIGN KEY(document_id, target_id) REFERENCES blocks(document_id, id) ON DELETE CASCADE
);
CREATE TABLE history (
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    sequence INTEGER NOT NULL CHECK(sequence > 0),
    commands BLOB NOT NULL,
    before_snapshot BLOB NOT NULL,
    after_snapshot BLOB NOT NULL,
    PRIMARY KEY(document_id, sequence)
);
PRAGMA user_version = 1;
