/// One immutable step in the durable SQLite schema history.
internal struct SqliteMigration: Sendable {
    let version: Int
    let statements: [String]
}

// These SQL strings match the historical names and checks in upstream migrations.ts.
// next_id is TEXT because node:sqlite rejects INTEGER results above its safe range.
internal let sqliteMigrations = makeSqliteMigrations(for: .default)

internal func makeSqliteMigrations(for schema: SqliteSchema) -> [SqliteMigration] {
    [SqliteMigration(version: 1, statements: [
#"""
CREATE TABLE \#(schema.tables.durableMetadata) (
		singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
		next_id TEXT NOT NULL,
		next_seq INTEGER NOT NULL
	) STRICT
"""#,
        #"INSERT INTO \#(schema.tables.durableMetadata) (singleton, next_id, next_seq) VALUES (1, '2', 1)"#,
#"""
CREATE TABLE \#(schema.tables.recordIds) (
		id INTEGER PRIMARY KEY,
		record_type TEXT NOT NULL CHECK (record_type IN ('conversation', 'entry', 'task', 'submission', 'document'))
	) STRICT
"""#,
#"""
CREATE TABLE \#(schema.tables.conversations) (
		id INTEGER PRIMARY KEY,
		owner_conversation_id INTEGER,
		owner_task_id INTEGER,
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX \#(schema.indexes.conversationsByOwnerConversation) ON \#(schema.tables.conversations) (owner_conversation_id, id)"#,
        #"CREATE INDEX \#(schema.indexes.conversationsByOwnerTask) ON \#(schema.tables.conversations) (owner_task_id, id)"#,
#"""
CREATE TABLE \#(schema.tables.entries) (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		head INTEGER,
		commit_seq INTEGER NOT NULL,
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX \#(schema.indexes.entriesByConversation) ON \#(schema.tables.entries) (conversation_id, id DESC)"#,
        #"CREATE INDEX \#(schema.indexes.entryHeadsByConversation) ON \#(schema.tables.entries) (conversation_id, id DESC) WHERE head IS NOT NULL"#,
#"""
CREATE TABLE \#(schema.tables.tasks) (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		kind TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'waiting', 'completing', 'terminal')),
		abort_requested INTEGER NOT NULL CHECK (abort_requested IN (0, 1)),
		background INTEGER NOT NULL CHECK (background IN (0, 1)),
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX \#(schema.indexes.tasksByStatus) ON \#(schema.tables.tasks) (status, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByConversation) ON \#(schema.tables.tasks) (conversation_id, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByKind) ON \#(schema.tables.tasks) (kind, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByAbortRequested) ON \#(schema.tables.tasks) (abort_requested, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByBackground) ON \#(schema.tables.tasks) (background, id)"#,
#"""
CREATE TABLE \#(schema.tables.submissions) (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		request_id TEXT,
		status TEXT NOT NULL CHECK (status IN ('queued', 'placed', 'done', 'unanswered')),
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
        #"CREATE INDEX \#(schema.indexes.submissionsByRequest) ON \#(schema.tables.submissions) (conversation_id, request_id)"#,
        #"CREATE INDEX \#(schema.indexes.submissionsByConversation) ON \#(schema.tables.submissions) (conversation_id, id)"#,
        #"CREATE INDEX \#(schema.indexes.submissionsByStatus) ON \#(schema.tables.submissions) (status, id)"#,
#"""
CREATE TABLE \#(schema.tables.documents) (
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
CREATE INDEX \#(schema.indexes.documentsByAddress)
		ON \#(schema.tables.documents) (kind, scope_kind, owner_id, family, key_value, created_at DESC, retired_at)
"""#,
        #"CREATE INDEX \#(schema.indexes.documentsByScope) ON \#(schema.tables.documents) (scope_kind, owner_id, id)"#,
        #"CREATE INDEX \#(schema.indexes.documentsByScopeKind) ON \#(schema.tables.documents) (scope_kind, owner_id, kind, id)"#,
#"""
CREATE TABLE \#(schema.tables.documentRevisions) (
		document_id INTEGER NOT NULL,
		seq INTEGER NOT NULL,
		kind TEXT NOT NULL CHECK (kind IN ('base', 'delta')),
		version INTEGER NOT NULL,
		content TEXT NOT NULL CHECK (json_valid(content)),
		PRIMARY KEY (document_id, seq)
	) STRICT
"""#,
        #"CREATE INDEX \#(schema.indexes.documentRevisionsByKind) ON \#(schema.tables.documentRevisions) (document_id, kind, seq DESC)"#,
    ]), SqliteMigration(version: 2, statements: [
// Upstream v1.4.0 durable/src/storage/sqlite/migrations.ts:91 rebuilds this CHECK.
#"""
CREATE TABLE \#(schema.tables.tasks)_v2 (
		id INTEGER PRIMARY KEY,
		conversation_id INTEGER NOT NULL,
		kind TEXT NOT NULL,
		status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'waiting', 'sleeping', 'completing', 'terminal')),
		abort_requested INTEGER NOT NULL CHECK (abort_requested IN (0, 1)),
		background INTEGER NOT NULL CHECK (background IN (0, 1)),
		record TEXT NOT NULL CHECK (json_valid(record))
	) STRICT
"""#,
#"""
INSERT INTO \#(schema.tables.tasks)_v2 (id, conversation_id, kind, status, abort_requested, background, record)
		SELECT id, conversation_id, kind, status, abort_requested, background, record FROM \#(schema.tables.tasks)
"""#,
        #"DROP TABLE \#(schema.tables.tasks)"#,
        #"ALTER TABLE \#(schema.tables.tasks)_v2 RENAME TO \#(schema.tables.tasks)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByStatus) ON \#(schema.tables.tasks) (status, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByConversation) ON \#(schema.tables.tasks) (conversation_id, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByKind) ON \#(schema.tables.tasks) (kind, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByAbortRequested) ON \#(schema.tables.tasks) (abort_requested, id)"#,
        #"CREATE INDEX \#(schema.indexes.tasksByBackground) ON \#(schema.tables.tasks) (background, id)"#,
    ])]
}

internal let currentSqliteSchemaVersion = sqliteMigrations.last?.version ?? 0

/// Apply pending schema changes in one transaction.
internal func applySqliteMigrations(
    _ database: any SqliteExecutor,
    schema: SqliteSchema = .default,
    migrations suppliedMigrations: [SqliteMigration]? = nil
) throws {
    let migrations = suppliedMigrations ?? makeSqliteMigrations(for: schema)
    for (index, migration) in migrations.enumerated() {
        guard migration.version == index + 1 else { throw SqliteFacadeError.invalidMigrations }
    }
    try database.transaction { transaction in
        try transaction.exec(
#"""
CREATE TABLE IF NOT EXISTS \#(schema.tables.durableSchema) (
			singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
			version INTEGER NOT NULL CHECK (version >= 0)
		) STRICT
"""#
        )
        try transaction.run("INSERT OR IGNORE INTO \(schema.tables.durableSchema) (singleton, version) VALUES (1, 0)")
        guard let row = try transaction.get("SELECT version FROM \(schema.tables.durableSchema) WHERE singleton = 1"),
              let version = row["version"]?.integerValue else { throw SqliteFacadeError.missingSchema }
        let currentVersion = migrations.last?.version ?? 0
        guard version <= currentVersion else {
            throw SqliteFacadeError.newerSchema(found: Int(version), supported: currentVersion)
        }
        for migration in migrations where migration.version > version {
            for statement in migration.statements { try transaction.exec(statement) }
            try transaction.run("UPDATE \(schema.tables.durableSchema) SET version = ? WHERE singleton = 1", [.integer(Int64(migration.version))])
        }
    }
}
