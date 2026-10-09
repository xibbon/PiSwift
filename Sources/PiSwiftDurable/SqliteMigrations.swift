/// One immutable step in the durable SQLite schema history.
internal struct SqliteMigration: Sendable {
    let version: Int
    let statements: [String]
}

// These SQL strings match migrations.ts at v1.1.0, including its names and checks.
// next_id is TEXT because node:sqlite rejects INTEGER results above its safe range.
internal let sqliteMigrations: [SqliteMigration] = [
    SqliteMigration(version: 1, statements: [
#"""
CREATE TABLE durable_metadata (
		singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
		next_id TEXT NOT NULL,
		next_seq INTEGER NOT NULL
	) STRICT
"""#,
        #"INSERT INTO durable_metadata (singleton, next_id, next_seq) VALUES (1, '2', 1)"#,
#"""
CREATE TABLE record_ids (
		id INTEGER PRIMARY KEY,
		record_type TEXT NOT NULL CHECK (record_type IN ('conversation', 'entry', 'task', 'submission', 'document'))
	) STRICT
"""#,
#"""
CREATE TABLE conversations (
		id INTEGER PRIMARY KEY,
		owner_conversation_id INTEGER,
		owner_task_id INTEGER,
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX conversations_by_owner_conversation ON conversations (owner_conversation_id, id)"#,
        #"CREATE INDEX conversations_by_owner_task ON conversations (owner_task_id, id)"#,
#"""
CREATE TABLE entries (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		head INTEGER,
		commit_seq INTEGER NOT NULL,
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX entries_by_conversation ON entries (conversation_id, id DESC)"#,
        #"CREATE INDEX entry_heads_by_conversation ON entries (conversation_id, id DESC) WHERE head IS NOT NULL"#,
#"""
CREATE TABLE tasks (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		kind TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'waiting', 'completing', 'terminal')),
		abort_requested INTEGER NOT NULL CHECK (abort_requested IN (0, 1)),
		background INTEGER NOT NULL CHECK (background IN (0, 1)),
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX tasks_by_status ON tasks (status, id)"#,
        #"CREATE INDEX tasks_by_conversation ON tasks (conversation_id, id)"#,
        #"CREATE INDEX tasks_by_kind ON tasks (kind, id)"#,
        #"CREATE INDEX tasks_by_abort_requested ON tasks (abort_requested, id)"#,
        #"CREATE INDEX tasks_by_background ON tasks (background, id)"#,
#"""
CREATE TABLE submissions (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		request_id TEXT,
		status TEXT NOT NULL CHECK (status IN ('queued', 'placed', 'done', 'unanswered')),
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX submissions_by_request ON submissions (conversation_id, request_id)"#,
        #"CREATE INDEX submissions_by_conversation ON submissions (conversation_id, id)"#,
        #"CREATE INDEX submissions_by_status ON submissions (status, id)"#,
#"""
CREATE TABLE documents (
		id INTEGER PRIMARY KEY,
		kind TEXT NOT NULL,
		family INTEGER NOT NULL CHECK (family IN (0, 1)),
		key_value TEXT NOT NULL,
		scope_kind TEXT NOT NULL CHECK (scope_kind IN ('session', 'conversation', 'task')),
		owner_id INTEGER NOT NULL,
		created_at INTEGER NOT NULL,
		retired_at INTEGER,
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
#"""
CREATE INDEX documents_by_address
		ON documents (kind, scope_kind, owner_id, family, key_value, created_at DESC, retired_at)
"""#,
        #"CREATE INDEX documents_by_scope ON documents (scope_kind, owner_id, id)"#,
        #"CREATE INDEX documents_by_scope_kind ON documents (scope_kind, owner_id, kind, id)"#,
#"""
CREATE TABLE document_revisions (
		document_id INTEGER NOT NULL,
		seq INTEGER NOT NULL,
		kind TEXT NOT NULL CHECK (kind IN ('base', 'delta')),
		version INTEGER NOT NULL,
		content TEXT NOT NULL CHECK (json_valid(content)),
		PRIMARY KEY (document_id, seq)
	) STRICT
"""#,
        #"CREATE INDEX document_revisions_by_kind ON document_revisions (document_id, kind, seq DESC)"#,
    ]),
]

internal let currentSqliteSchemaVersion = sqliteMigrations.last?.version ?? 0

/// Apply pending schema changes in one transaction.
internal func applySqliteMigrations(
    _ database: any SqliteExecutor,
    migrations: [SqliteMigration] = sqliteMigrations
) throws {
    for (index, migration) in migrations.enumerated() {
        guard migration.version == index + 1 else { throw SqliteFacadeError.invalidMigrations }
    }
    try database.transaction { transaction in
        try transaction.exec(
#"""
CREATE TABLE IF NOT EXISTS durable_schema (
			singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
			version INTEGER NOT NULL CHECK (version >= 0)
		) STRICT
"""#
        )
        try transaction.run("INSERT OR IGNORE INTO durable_schema (singleton, version) VALUES (1, 0)")
        guard let row = try transaction.get("SELECT version FROM durable_schema WHERE singleton = 1"),
              let version = row["version"]?.integerValue else { throw SqliteFacadeError.missingSchema }
        let currentVersion = migrations.last?.version ?? 0
        guard version <= currentVersion else {
            throw SqliteFacadeError.newerSchema(found: Int(version), supported: currentVersion)
        }
        for migration in migrations where migration.version > version {
            for statement in migration.statements { try transaction.exec(statement) }
            try transaction.run("UPDATE durable_schema SET version = ? WHERE singleton = 1", [.integer(Int64(migration.version))])
        }
    }
}
