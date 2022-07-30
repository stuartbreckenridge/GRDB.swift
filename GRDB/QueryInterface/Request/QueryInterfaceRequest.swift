// QueryInterfaceRequest is the type of requests generated by TableRecord:
//
//     struct Player: TableRecord { ... }
//     let playerRequest = Player.all() // QueryInterfaceRequest<Player>
//
// It wraps an SQLQuery, and has an attached type.
//
// The attached RowDecoder type helps decoding raw database values:
//
//     try dbQueue.read { db in
//         try playerRequest.fetchAll(db) // [Player]
//     }
//
// RowDecoder also helps the compiler validate associated requests:
//
//     playerRequest.including(required: Player.team) // OK
//     fruitRequest.including(required: Player.team)  // Does not compile

/// QueryInterfaceRequest is a request that generates SQL for you.
///
/// For example:
///
///     try dbQueue.read { db in
///         let request = Player
///             .filter(Column("score") > 1000)
///             .order(Column("name"))
///         let players = try request.fetchAll(db) // [Player]
///     }
///
/// See <https://github.com/groue/GRDB.swift#the-query-interface>
public struct QueryInterfaceRequest<RowDecoder> {
    var relation: SQLRelation
}

extension QueryInterfaceRequest: Refinable { }

extension QueryInterfaceRequest: FetchRequest {
    public var sqlSubquery: SQLSubquery {
        .relation(relation)
    }
    
    public func fetchCount(_ db: Database) throws -> Int {
        try relation.fetchCount(db)
    }
    
    public func makePreparedRequest(
        _ db: Database,
        forSingleResult singleResult: Bool = false)
    throws -> PreparedRequest
    {
        let generator = SQLQueryGenerator(relation: relation, forSingleResult: singleResult)
        var preparedRequest = try generator.makePreparedRequest(db)
        let associations = relation.prefetchedAssociations
        if associations.isEmpty == false {
            // Eager loading of prefetched associations
            preparedRequest.supplementaryFetch = { [relation] db, rows in
                try prefetch(db, associations: associations, from: relation, into: rows)
            }
        }
        return preparedRequest
    }
}

// MARK: - Request Derivation

extension QueryInterfaceRequest: SelectionRequest {
    /// Creates a request which selects *selection promise*.
    ///
    ///     // SELECT id, email FROM player
    ///     var request = Player.all()
    ///     request = request.select { db in [Column("id"), Column("email")] }
    ///
    /// Any previous selection is replaced:
    ///
    ///     // SELECT email FROM player
    ///     request
    ///         .select { db in [Column("id")] }
    ///         .select { db in [Column("email")] }
    public func select(_ selection: @escaping (Database) throws -> [any SQLSelectable]) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.select { db in
                try selection(db).map(\.sqlSelection)
            }
        }
    }
    
    /// Creates a request which selects *selection*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select([max(Column("score"))], as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(_ selection: [any SQLSelectable], as type: RowDecoder.Type = RowDecoder.self)
    -> QueryInterfaceRequest<RowDecoder>
    {
        select(selection).asRequest(of: RowDecoder.self)
    }
    
    /// Creates a request which selects *selection*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select(max(Column("score")), as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(_ selection: any SQLSelectable..., as type: RowDecoder.Type = RowDecoder.self)
    -> QueryInterfaceRequest<RowDecoder>
    {
        select(selection, as: type)
    }
    
    /// Creates a request which selects *sql*, and fetches values of
    /// type *type*.
    ///
    ///     try dbQueue.read { db in
    ///         // SELECT max(score) FROM player
    ///         let request = Player.all().select(sql: "max(score)", as: Int.self)
    ///         let maxScore: Int? = try request.fetchOne(db)
    ///     }
    public func select<RowDecoder>(
        sql: String,
        arguments: StatementArguments = StatementArguments(),
        as type: RowDecoder.Type = RowDecoder.self)
    -> QueryInterfaceRequest<RowDecoder>
    {
        select(SQL(sql: sql, arguments: arguments), as: type)
    }
    
    /// Creates a request which selects an SQL *literal*, and fetches values of
    /// type *type*.
    ///
    /// Literals allow you to safely embed raw values in your SQL, without any
    /// risk of syntax errors or SQL injection:
    ///
    ///     // SELECT IFNULL(name, 'Anonymous') FROM player
    ///     let defaultName = "Anonymous"
    ///     let request = Player.all().select(
    ///         literal: "IFNULL(name, \(defaultName))",
    ///         as: String.self)
    ///     let name: String? = try request.fetchOne(db)
    public func select<RowDecoder>(
        literal sqlLiteral: SQL,
        as type: RowDecoder.Type = RowDecoder.self)
    -> QueryInterfaceRequest<RowDecoder>
    {
        select(sqlLiteral, as: type)
    }
    
    /// Creates a request which selects the primary key.
    ///
    /// All primary keys are supported:
    ///
    ///     // SELECT id FROM player WHERE ...
    ///     let request = try Player.filter(...).selectPrimaryKey(as: Int64.self)
    ///
    ///     // SELECT code FROM country WHERE ...
    ///     let request = try Country.filter(...).selectPrimaryKey(as: String.self)
    ///
    ///     // SELECT citizenId, countryCode FROM citizenship WHERE ...
    ///     let request = try Citizenship.filter(...).selectPrimaryKey(as: Row.self)
    public func selectPrimaryKey<PrimaryKey>(as type: PrimaryKey.Type = PrimaryKey.self)
    -> QueryInterfaceRequest<PrimaryKey>
    {
        with { request in
            let tableName = request.relation.source.tableName
            request.relation = request.relation.select { db in
                try db.primaryKey(tableName).columns.map { Column($0).sqlSelection }
            }
        }
        .asRequest(of: PrimaryKey.self)
    }
    
    /// Creates a request which appends *selection promise*.
    ///
    ///     // SELECT id, email, name FROM player
    ///     var request = Player.all()
    ///     request = request
    ///         .select([Column("id"), Column("email")])
    ///         .annotated(with: { db in [Column("name")] })
    public func annotated(with selection: @escaping (Database) throws -> [any SQLSelectable]) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.annotated { db in
                try selection(db).map(\.sqlSelection)
            }
        }
    }
}

extension QueryInterfaceRequest: FilteredRequest {
    /// Creates a request with the provided *predicate promise* added to the
    /// eventual set of already applied predicates.
    ///
    ///     // SELECT * FROM player WHERE 1
    ///     var request = Player.all()
    ///     request = request.filter { db in true }
    public func filter(_ predicate: @escaping (Database) throws -> any SQLExpressible) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.filter { db in
                try predicate(db).sqlExpression
            }
        }
    }
}

extension QueryInterfaceRequest: OrderedRequest {
    /// Creates a request with the provided *orderings promise*.
    ///
    ///     // SELECT * FROM player ORDER BY name
    ///     var request = Player.all()
    ///     request = request.order { _ in [Column("name")] }
    ///
    /// Any previous ordering is replaced:
    ///
    ///     // SELECT * FROM player ORDER BY name
    ///     request
    ///         .order{ _ in [Column("email")] }
    ///         .reversed()
    ///         .order{ _ in [Column("name")] }
    public func order(_ orderings: @escaping (Database) throws -> [any SQLOrderingTerm]) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.order { db in
                try orderings(db).map(\.sqlOrdering)
            }
        }
    }
    
    /// Creates a request that reverses applied orderings.
    ///
    ///     // SELECT * FROM player ORDER BY name DESC
    ///     var request = Player.all().order(Column("name"))
    ///     request = request.reversed()
    ///
    /// If no ordering was applied, the returned request is identical.
    ///
    ///     // SELECT * FROM player
    ///     var request = Player.all()
    ///     request = request.reversed()
    public func reversed() -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.reversed()
        }
    }
    
    /// Creates a request without any ordering.
    ///
    ///     // SELECT * FROM player
    ///     var request = Player.all().order(Column("name"))
    ///     request = request.unordered()
    public func unordered() -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.unordered()
        }
    }
}

extension QueryInterfaceRequest: AggregatingRequest {
    /// Creates a request grouped according to *expressions promise*.
    public func group(_ expressions: @escaping (Database) throws -> [any SQLExpressible]) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.group { db in
                try expressions(db).map(\.sqlExpression)
            }
        }
    }
    
    /// Creates a request with the provided *predicate promise* added to the
    /// eventual set of already applied predicates.
    public func having(_ predicate: @escaping (Database) throws -> any SQLExpressible) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.having { db in
                try predicate(db).sqlExpression
            }
        }
    }
}

/// :nodoc:
extension QueryInterfaceRequest: _JoinableRequest {
    /// :nodoc:
    public func _including(all association: _SQLAssociation) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation._including(all: association)
        }
    }
    
    /// :nodoc:
    public func _including(optional association: _SQLAssociation) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation._including(optional: association)
        }
    }
    
    /// :nodoc:
    public func _including(required association: _SQLAssociation) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation._including(required: association)
        }
    }
    
    /// :nodoc:
    public func _joining(optional association: _SQLAssociation) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation._joining(optional: association)
        }
    }
    
    /// :nodoc:
    public func _joining(required association: _SQLAssociation) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation._joining(required: association)
        }
    }
}

extension QueryInterfaceRequest: JoinableRequest { }

extension QueryInterfaceRequest: TableRequest {
    /// :nodoc:
    public var databaseTableName: String {
        relation.source.tableName
    }
    
    /// Creates a request that allows you to define expressions that target
    /// a specific database table.
    ///
    /// In the example below, the "team.avgScore < player.score" condition in
    /// the ON clause could be not achieved without table aliases.
    ///
    ///     struct Player: TableRecord {
    ///         static let team = belongsTo(Team.self)
    ///     }
    ///
    ///     // SELECT player.*, team.*
    ///     // JOIN team ON ... AND team.avgScore < player.score
    ///     let playerAlias = TableAlias()
    ///     let request = Player
    ///         .all()
    ///         .aliased(playerAlias)
    ///         .including(required: Player.team.filter(Column("avgScore") < playerAlias[Column("score")])
    public func aliased(_ alias: TableAlias) -> QueryInterfaceRequest {
        with {
            $0.relation = $0.relation.aliased(alias)
        }
    }
}

extension QueryInterfaceRequest: DerivableRequest {
    public func distinct() -> QueryInterfaceRequest {
        with {
            $0.relation.isDistinct = true
        }
    }
    
    /// Creates a request which fetches *limit* rows, starting at *offset*.
    ///
    ///     // SELECT * FROM player LIMIT 10 OFFSET 20
    ///     var request = Player.all()
    ///     request = request.limit(10, offset: 20)
    ///
    /// Any previous limit is replaced.
    public func limit(_ limit: Int, offset: Int? = nil) -> QueryInterfaceRequest {
        with {
            $0.relation.limit = SQLLimit(limit: limit, offset: offset)
        }
    }
    
    public func with<RowDecoder>(_ cte: CommonTableExpression<RowDecoder>) -> Self {
        with {
            $0.relation.ctes[cte.tableName] = cte.cte
        }
    }
}

extension QueryInterfaceRequest {
    /// Creates a request bound to type RowDecoder.
    ///
    /// The returned request can fetch if the type RowDecoder is fetchable (Row,
    /// value, record).
    ///
    ///     // Int?
    ///     let maxScore = try Player
    ///         .select(max(scoreColumn))
    ///         .asRequest(of: Int.self)    // <--
    ///         .fetchOne(db)
    ///
    /// - parameter type: The fetched type RowDecoder
    /// - returns: A request bound to type RowDecoder.
    public func asRequest<RowDecoder>(of type: RowDecoder.Type) -> QueryInterfaceRequest<RowDecoder> {
        QueryInterfaceRequest<RowDecoder>(relation: relation)
    }
}

// MARK: - Check Existence

extension QueryInterfaceRequest {
    /// Returns true if the request matches no row in the database.
    ///
    ///     try Player.filter(Column("name") == "Arthur").isEmpty(db)
    ///
    /// - parameter db: A database connection.
    /// - returns: Whether the request matches no row in the database.
    public func isEmpty(_ db: Database) throws -> Bool {
        try !SQLRequest("SELECT \(exists())").fetchOne(db)!
    }
}

// MARK: - Batch Delete

extension QueryInterfaceRequest {
    /// Deletes matching rows; returns the number of deleted rows.
    ///
    /// - parameter db: A database connection.
    /// - returns: The number of deleted rows
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func deleteAll(_ db: Database) throws -> Int {
        try SQLQueryGenerator(relation: relation).makeDeleteStatement(db).execute()
        return db.changesCount
    }
}

// MARK: - Batch Update

extension QueryInterfaceRequest {
    /// The conflict resolution to use for batch updates
    private var defaultConflictResolutionForUpdate: Database.ConflictResolution {
        // In order to look for the default conflict resolution, we perform a
        // runtime check for MutablePersistableRecord, and look for a
        // user-defined default. Such dynamic dispatch is unusual in GRDB, but
        // static dispatch is likely to create bad surprises in generic contexts.
        if let recordType = RowDecoder.self as? any MutablePersistableRecord.Type {
            return recordType.persistenceConflictPolicy.conflictResolutionForUpdate
        } else {
            return .abort
        }
    }
    
    /// Updates matching rows; returns the number of updated rows.
    ///
    /// For example:
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.all().updateAll(db, [Column("score").set(to: 0)])
    ///     }
    ///
    /// - parameter db: A database connection.
    /// - parameter conflictResolution: A policy for conflict resolution.
    /// - parameter assignments: An array of column assignments.
    /// - returns: The number of updated rows.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func updateAll(
        _ db: Database,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignments: [ColumnAssignment]) throws -> Int
    {
        let conflictResolution = conflictResolution ?? defaultConflictResolutionForUpdate
        guard let updateStatement = try SQLQueryGenerator(relation: relation).makeUpdateStatement(
                db,
                conflictResolution: conflictResolution,
                assignments: assignments) else
        {
            // database not hit
            return 0
        }
        try updateStatement.execute()
        return db.changesCount
    }
    
    /// Updates matching rows; returns the number of updated rows.
    ///
    /// For example:
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.all().updateAll(db, Column("score").set(to: 0))
    ///     }
    ///
    /// - parameter db: A database connection.
    /// - parameter conflictResolution: A policy for conflict resolution.
    /// - parameter assignment: A column assignment.
    /// - parameter otherAssignments: Eventual other column assignments.
    /// - returns: The number of updated rows.
    /// - throws: A DatabaseError is thrown whenever an SQLite error occurs.
    @discardableResult
    public func updateAll(
        _ db: Database,
        onConflict conflictResolution: Database.ConflictResolution? = nil,
        _ assignment: ColumnAssignment,
        _ otherAssignments: ColumnAssignment...)
    throws -> Int
    {
        try updateAll(db, onConflict: conflictResolution, [assignment] + otherAssignments)
    }
}

// MARK: - ColumnAssignment

/// A ColumnAssignment can update rows in the database.
///
/// You create an assignment from a column and an assignment method or operator,
/// such as `set(to:)` or `+=`:
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = 0
///         let assignment = Column("score").set(to: 0)
///         try Player.updateAll(db, assignment)
///     }
public struct ColumnAssignment {
    var columnName: String
    var value: SQLExpression
    
    func sql(_ context: SQLGenerationContext) throws -> String {
        try Column(columnName).sqlExpression.sql(context) + " = " + value.sql(context)
    }
}

extension ColumnExpression {
    /// Creates an assignment to a value.
    ///
    ///     Column("valid").set(to: true)
    ///     Column("score").set(to: 0)
    ///     Column("score").set(to: nil)
    ///     Column("score").set(to: Column("score") + Column("bonus"))
    ///
    ///     try dbQueue.write { db in
    ///         // UPDATE player SET score = 0
    ///         try Player.updateAll(db, Column("score").set(to: 0))
    ///     }
    public func set(to value: (any SQLExpressible)?) -> ColumnAssignment {
        ColumnAssignment(columnName: name, value: value?.sqlExpression ?? .null)
    }
}

/// Creates an assignment that adds a value
///
///     Column("score") += 1
///     Column("score") += Column("bonus")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score + 1
///         try Player.updateAll(db, Column("score") += 1)
///     }
public func += (column: some ColumnExpression, value: some SQLExpressible) -> ColumnAssignment {
    column.set(to: column + value)
}

/// Creates an assignment that subtracts a value
///
///     Column("score") -= 1
///     Column("score") -= Column("bonus")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score - 1
///         try Player.updateAll(db, Column("score") -= 1)
///     }
public func -= (column: some ColumnExpression, value: some SQLExpressible) -> ColumnAssignment {
    column.set(to: column - value)
}

/// Creates an assignment that multiplies by a value
///
///     Column("score") *= 2
///     Column("score") *= Column("factor")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score * 2
///         try Player.updateAll(db, Column("score") *= 2)
///     }
public func *= (column: some ColumnExpression, value: some SQLExpressible) -> ColumnAssignment {
    column.set(to: column * value)
}

/// Creates an assignment that divides by a value
///
///     Column("score") /= 2
///     Column("score") /= Column("factor")
///
///     try dbQueue.write { db in
///         // UPDATE player SET score = score / 2
///         try Player.updateAll(db, Column("score") /= 2)
///     }
public func /= (column: some ColumnExpression, value: some SQLExpressible) -> ColumnAssignment {
    column.set(to: column / value)
}

// MARK: - Eager loading of hasMany associations

// CAUTION: Keep this code in sync with prefetchedRegion(_:_:)
/// Append rows from prefetched associations into the `originRows` argument.
///
/// - parameter db: A database connection.
/// - parameter associations: Prefetched associations.
/// - parameter originRows: The rows that need to be extended with prefetched rows.
/// - parameter originQuery: The query that was used to fetch `originRows`.
private func prefetch(
    _ db: Database,
    associations: [_SQLAssociation],
    from originRelation: SQLRelation,
    into originRows: [Row]) throws
{
    guard let firstOriginRow = originRows.first else {
        // No rows -> no prefetch
        return
    }
    
    for association in associations {
        switch association.pivot.condition {
        case .expression:
            // Likely a GRDB bug: such condition only exist for CTEs, which
            // are not prefetched with including(all:)
            fatalError("Not implemented: prefetch association without any foreign key")
            
        case let .foreignKey(pivotForeignKey):
            let originTable = originRelation.source.tableName
            let pivotMapping = try pivotForeignKey.joinMapping(db, from: originTable)
            let pivotColumns = pivotMapping.map(\.right)
            let leftColumns = pivotMapping.map(\.left)
            
            // We want to avoid the "Expression tree is too large" SQLite error
            // when the foreign key contains several columns, and there are many
            // base rows that overflow SQLITE_LIMIT_EXPR_DEPTH:
            // https://github.com/groue/GRDB.swift/issues/871
            //
            //      -- May be too complex for the SQLite engine
            //      SELECT * FROM child
            //      WHERE (a = ? AND b = ?)
            //         OR (a = ? AND b = ?)
            //         OR ...
            //
            // Instead, we do not inject any value from the base rows in
            // the prefetch request. Instead, we directly inject the base
            // request as a common table expression (CTE):
            //
            //      WITH grdb_base AS (SELECT a, b FROM parent)
            //      SELECT * FROM child
            //      WHERE (a, b) IN grdb_base
            let usesCommonTableExpression = pivotMapping.count > 1
            
            let prefetchRequest: QueryInterfaceRequest<Row>
            if usesCommonTableExpression {
                // HasMany: Author.including(all: Author.books)
                //
                //      WITH grdb_base AS (SELECT a, b FROM author)
                //      SELECT book.*, book.authorId AS grdb_authorId
                //      FROM book
                //      WHERE (book.a, book.b) IN grdb_base
                //
                // HasManyThrough: Citizen.including(all: Citizen.countries)
                //
                //      WITH grdb_base AS (SELECT a, b FROM citizen)
                //      SELECT country.*, passport.citizenId AS grdb_citizenId
                //      FROM country
                //      JOIN passport ON passport.countryCode = country.code
                //                    AND (passport.a, passport.b) IN grdb_base
                //
                // In the CTE, ordering and including(all:) children are
                // useless, and we only need to select pivot columns:
                let originRelation = originRelation
                    .unorderedUnlessLimited() // only preserve ordering in the CTE if limited
                    .removingChildrenForPrefetchedAssociations()
                    .selectOnly(leftColumns.map { SQLExpression.column($0).sqlSelection })
                let originCTE = CommonTableExpression(
                    named: "grdb_base",
                    request: SQLSubquery.relation(originRelation))
                let pivotRowValue = SQLExpression.rowValue(pivotColumns.map(SQLExpression.column))!
                let pivotFilter = originCTE.contains(pivotRowValue)
                
                prefetchRequest = makePrefetchRequest(
                    for: association,
                    filteringPivotWith: pivotFilter,
                    annotatedWith: pivotColumns)
                    .with(originCTE)
            } else {
                // HasMany: Author.including(all: Author.books)
                //
                //      SELECT *, authorId AS grdb_authorId
                //      FROM book
                //      WHERE authorId IN (1, 2, 3)
                //
                // HasManyThrough: Citizen.including(all: Citizen.countries)
                //
                //      SELECT country.*, passport.citizenId AS grdb_citizenId
                //      FROM country
                //      JOIN passport ON passport.countryCode = country.code
                //                    AND passport.citizenId IN (1, 2, 3)
                let pivotFilter = pivotMapping.joinExpression(leftRows: originRows)
                
                prefetchRequest = makePrefetchRequest(
                    for: association,
                    filteringPivotWith: pivotFilter,
                    annotatedWith: pivotColumns)
            }
            
            let prefetchedRows = try prefetchRequest.fetchAll(db)
            let prefetchedGroups = prefetchedRows.grouped(byDatabaseValuesOnColumns: pivotColumns.map { "grdb_\($0)" })
            let groupingIndexes = firstOriginRow.indexes(forColumns: leftColumns)
            
            for row in originRows {
                let groupingKey = groupingIndexes.map { row.impl.databaseValue(atUncheckedIndex: $0) }
                let prefetchedRows = prefetchedGroups[groupingKey, default: []]
                row.prefetchedRows.setRows(prefetchedRows, forKeyPath: association.keyPath)
            }
        }
    }
}

/// Returns a request for prefetched rows.
///
/// - parameter assocciation: The prefetched association.
/// - parameter pivotFilter: The expression that filters the pivot of
///   the association.
/// - parameter pivotColumns: The pivot columns that annotate the
///   returned request.
func makePrefetchRequest(
    for association: _SQLAssociation,
    filteringPivotWith pivotFilter: SQLExpression,
    annotatedWith pivotColumns: [String])
-> QueryInterfaceRequest<Row>
{
    // We annotate prefetched rows with pivot columns, so that we can
    // group them.
    //
    // Those pivot columns are necessary when we prefetch
    // indirect associations:
    //
    //      // SELECT country.*, passport.citizenId AS grdb_citizenId
    //      // --                ^ the necessary pivot column
    //      // FROM country
    //      // JOIN passport ON passport.countryCode = country.code
    //      //               AND passport.citizenId IN (1, 2, 3)
    //      Citizen.including(all: Citizen.countries)
    //
    // Those pivot columns are redundant when we prefetch direct
    // associations (maybe we'll remove this redundancy later):
    //
    //      // SELECT *, authorId AS grdb_authorId
    //      // --        ^ the redundant pivot column
    //      // FROM book
    //      // WHERE authorId IN (1, 2, 3)
    //      Author.including(all: Author.books)
    let pivotAlias = TableAlias()
    
    let prefetchRelation = association
        .with {
            $0.pivot.relation = $0.pivot.relation
                .aliased(pivotAlias)
                .filter(pivotFilter)
        }
        .destinationRelation()
        .annotated(with: pivotColumns.map { pivotAlias[$0].forKey("grdb_\($0)") })
    
    return QueryInterfaceRequest<Row>(relation: prefetchRelation)
}

// CAUTION: Keep this code in sync with prefetch(_:associations:in:)
/// Returns the region of prefetched associations
func prefetchedRegion(
    _ db: Database,
    associations: [_SQLAssociation],
    from originTable: String)
throws -> DatabaseRegion
{
    try associations.reduce(into: DatabaseRegion()) { (region, association) in
        switch association.pivot.condition {
        case .expression:
            // Likely a GRDB bug: such condition only exist for CTEs, which
            // are not prefetched with including(all:)
            fatalError("Not implemented: prefetch association without any foreign key")
            
        case let .foreignKey(pivotForeignKey):
            let pivotMapping = try pivotForeignKey.joinMapping(db, from: originTable)
            let prefetchRegion = try prefetchedRegion(db, association: association, pivotMapping: pivotMapping)
            region.formUnion(prefetchRegion)
        }
    }
}

// CAUTION: Keep this code in sync with prefetch(_:associations:in:)
func prefetchedRegion(
    _ db: Database,
    association: _SQLAssociation,
    pivotMapping: JoinMapping)
throws -> DatabaseRegion
{
    // Filter the pivot on a `DummyRow` in order to make sure all join
    // condition columns are made visible to SQLite, and present in the
    // selected region:
    //  ... JOIN right ON right.leftId = ?
    //                                   ^ content of the DummyRow
    let pivotFilter = pivotMapping.joinExpression(leftRows: [DummyRow()])
    
    let prefetchRelation = association
        .with {
            $0.pivot.relation = $0.pivot.relation.filter(pivotFilter)
        }
        .destinationRelation()
    
    return try SQLQueryGenerator(relation: prefetchRelation)
        .makeStatement(db)
        .databaseRegion // contains region of nested associations
}

extension Array where Element == Row {
    /// - precondition: Columns all exist in all rows. All rows have the same
    ///   columnns, in the same order.
    fileprivate func grouped(byDatabaseValuesOnColumns columns: [String]) -> [[DatabaseValue]: [Row]] {
        guard let firstRow = first else {
            return [:]
        }
        let indexes = firstRow.indexes(forColumns: columns)
        return Dictionary(grouping: self, by: { row in
            indexes.map { row.impl.databaseValue(atUncheckedIndex: $0) }
        })
    }
}

extension Row {
    /// - precondition: Columns all exist in the row.
    fileprivate func indexes(forColumns columns: [String]) -> [Int] {
        columns.map { column in
            guard let index = index(forColumn: column) else {
                fatalError("Column \(column) is not selected")
            }
            return index
        }
    }
}
