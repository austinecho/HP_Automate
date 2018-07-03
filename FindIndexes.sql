USE RateIQ2;

DECLARE @TableNameFind VARCHAR(128) = 'RatingDetail';

IF OBJECT_ID('tempdb..#Temp') IS NOT NULL
    DROP TABLE #Temp;

SELECT  s.name AS SchemaName ,
        t.name AS TableName ,
        i.[name] IndexName ,
        c.[name] ColumnName ,
        CAST(ic.is_included_column AS INT) AS is_included_column ,
        i.index_id ,
        i.type_desc ,
        i.is_unique ,
        i.data_space_id ,
        i.ignore_dup_key ,
        i.is_primary_key ,
        i.is_unique_constraint
INTO    #Temp
FROM    sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id
                                     AND i.index_id = ic.index_id
        JOIN sys.columns c ON ic.object_id = c.object_id
                              AND ic.column_id = c.column_id
        JOIN sys.tables AS t ON i.object_id = t.object_id
        JOIN sys.schemas AS s ON t.schema_id = s.schema_id
WHERE   ( t.name = @TableNameFind
          OR @TableNameFind IS NULL
        )
        AND i.type_desc = 'NONCLUSTERED'
        AND i.is_primary_key = 0
        AND i.is_unique = 0
        AND i.is_unique_constraint = 0
ORDER BY s.name;

IF OBJECT_ID('tempdb..#IndexBreakDown') IS NOT NULL
    DROP TABLE #IndexBreakDown;

CREATE TABLE #IndexBreakDown
    (
      ID INT IDENTITY(1, 1) ,
      SchemaName VARCHAR(128) ,
      TableName VARCHAR(128) ,
      IndexName VARCHAR(128) ,
      HasInclude BIT ,
      IsProcessed BIT DEFAULT 0
    );

INSERT  INTO #IndexBreakDown
        ( SchemaName ,
          TableName ,
          IndexName ,
          HasInclude
        )
        SELECT  SchemaName ,
                TableName ,
                IndexName ,
                CASE WHEN SUM(is_included_column) >= 1 THEN 1
                     ELSE 0
                END AS HasInclude
        FROM    #Temp
        GROUP BY SchemaName ,
                TableName ,
                IndexName;

IF OBJECT_ID('tempdb..#Indexes') IS NOT NULL
    DROP TABLE #Indexes;

CREATE TABLE #Indexes
    (
      ID INT IDENTITY(1, 1) ,
      OldIndexName VARCHAR(128) ,
      NewIndexName VARCHAR(128) ,
      SchemaName VARCHAR(128) ,
      TableName VARCHAR(128) ,
      IndexOnColumns VARCHAR(MAX) NULL ,
      IsProcessed BIT DEFAULT 0
    );

DECLARE @SchemaName VARCHAR(128);
DECLARE @TableName VARCHAR(128);
DECLARE @IndexName VARCHAR(128);
DECLARE @PrefixSchemaTable VARCHAR(128);
DECLARE @IsIncl BIT;
DECLARE @Incl VARCHAR(5) = '_Incl';
DECLARE @Prefix VARCHAR(3) = 'IX_';
DECLARE @Names VARCHAR(128); 
DECLARE @ProcessedCount INT = 1;
DECLARE @FinalIndex VARCHAR(128);
DECLARE @Index VARCHAR(120);

WHILE @ProcessedCount > 0
    BEGIN

        SELECT TOP 1
                @SchemaName = SchemaName ,
                @TableName = TableName ,
                @IndexName = IndexName ,
                @IsIncl = HasInclude
        FROM    #IndexBreakDown
        WHERE   IsProcessed = 0;

        IF @SchemaName <> 'dbo'
            BEGIN 
                SELECT  @PrefixSchemaTable = @Prefix + SchemaName + '_'
                        + TableName
                FROM    #IndexBreakDown
                WHERE   SchemaName = @SchemaName
                        AND TableName = @TableName
                        AND IndexName = @IndexName;
            END;

        IF @SchemaName = 'dbo'
            BEGIN 
                SELECT  @PrefixSchemaTable = @Prefix + '_' + TableName
                FROM    #IndexBreakDown
                WHERE   SchemaName = @SchemaName
                        AND TableName = @TableName
                        AND IndexName = @IndexName;
            END;

        SET @Names = '';

        SELECT  @Names = COALESCE(@Names + '_', '') + ColumnName
        FROM    #Temp
        WHERE   SchemaName = @SchemaName
                AND TableName = @TableName
                AND IndexName = @IndexName
                AND is_included_column = 0;

        IF @IsIncl = 1
            BEGIN 

                SET @Index = @PrefixSchemaTable + @Names;
                SET @FinalIndex = @Index + @Incl;

            END;

        ELSE
            BEGIN

                SET @FinalIndex = @PrefixSchemaTable + @Names;

            END;

        INSERT  INTO #Indexes
                ( OldIndexName ,
                  NewIndexName ,
                  SchemaName ,
                  TableName
                )
                SELECT  @IndexName ,
                        @FinalIndex ,
                        @SchemaName ,
                        @TableName;

        UPDATE  #IndexBreakDown
        SET     IsProcessed = 1
        WHERE   SchemaName = @SchemaName
                AND TableName = @TableName
                AND IndexName = @IndexName;

        SELECT  @ProcessedCount = COUNT(1)
        FROM    #IndexBreakDown
        WHERE   IsProcessed = 0;

    END;

--============================================
-- Create Index
--============================================
IF OBJECT_ID('tempdb..#IndexScript') IS NOT NULL
    DROP TABLE #IndexScript;

CREATE TABLE #IndexScript ( Script VARCHAR(MAX) );

DECLARE @ColumnNames VARCHAR(MAX);
DECLARE @NewProcessCount INT = 1;
DECLARE @ID INT; 

DECLARE @NewIndexName VARCHAR(128);
DECLARE @IncludeColumns VARCHAR(MAX);

WHILE @NewProcessCount > 0
    BEGIN 

        SET @SchemaName = NULL;
        SET @TableName = NULL;
        SET @PrefixSchemaTable = NULL; 
        SET @IndexName = NULL; 
        SET @ColumnNames = NULL; 
        SET @ID = NULL; 
        SET @NewIndexName = NULL;
        SET @IncludeColumns = NULL;  

        SELECT TOP 1
                @IndexName = OldIndexName ,
                @ID = ID ,
                @SchemaName = SchemaName ,
                @TableName = TableName ,
                @NewIndexName = NewIndexName
        FROM    #Indexes
        WHERE   IsProcessed = 0;

        SET @PrefixSchemaTable = @SchemaName + '.' + @TableName;

        SELECT  @ColumnNames = COALESCE(@ColumnNames + ', ', '') + ColumnName
        FROM    #Temp AS T
                INNER JOIN #Indexes AS I ON T.IndexName = I.OldIndexName
                                            AND T.SchemaName = I.SchemaName
                                            AND T.TableName = I.TableName
        WHERE   I.ID = @ID
                AND T.is_included_column = 0;

        SELECT  @IncludeColumns = COALESCE(@IncludeColumns + '_', '')
                + ColumnName
        FROM    #Temp AS T
                INNER JOIN #Indexes AS I ON T.IndexName = I.OldIndexName
                                            AND T.SchemaName = I.SchemaName
                                            AND T.TableName = I.TableName
        WHERE   I.ID = @ID
                AND is_included_column = 1;

        IF @IncludeColumns IS NULL
            BEGIN

                INSERT  INTO #IndexScript
                        ( Script
                        )
                        SELECT  '
IF EXISTS ( SELECT 1 FROM sys.sysindexes WHERE name = '''+ @NewIndexName + ''' )
BEGIN
    DROP INDEX ' + @NewIndexName + ' ON ' + @SchemaName + '.' + @TableName
	+ ' PRINT ''- Index [' + @NewIndexName + '] Dropped''; 
END;

CREATE NONCLUSTERED INDEX ' + @NewIndexName + ' ON ' + @PrefixSchemaTable + '
( ' + @ColumnNames + ')';

            END;

        IF @IncludeColumns IS NOT NULL
            BEGIN

                INSERT  INTO #IndexScript
                        ( Script
                        )
                        SELECT  '
IF EXISTS ( SELECT 1 FROM sys.sysindexes WHERE name = '''+ @NewIndexName + ''' )
BEGIN
    DROP INDEX ' + @NewIndexName + ' ON ' + @SchemaName + '.' + @TableName
	+ ' PRINT ''- Index [' + @NewIndexName + '] Dropped''; 
END;

CREATE NONCLUSTERED INDEX ' + @NewIndexName + ' ON ' + @PrefixSchemaTable + '
( ' + @ColumnNames + ') INCLUDE (' + @IncludeColumns + ')';

            END;



        UPDATE  #Indexes
        SET     IsProcessed = 1
        WHERE   ID = @ID;

        SET @NewProcessCount = ( SELECT COUNT(1)
                                 FROM   #Indexes
                                 WHERE  IsProcessed = 0
                               );

    END;

IF OBJECT_ID('tempdb..#DropIndex') IS NOT NULL
    DROP TABLE #DropIndex;

CREATE TABLE #DropIndex
(
	Script VARCHAR(MAX)
)

UPDATE #IndexBreakDown
SET IsProcessed = 0

SET @NewProcessCount = 1

WHILE @NewProcessCount > 0
BEGIN

SET @SchemaName = NULL
SET @TableName = NULL
SET @IndexName = NULL
SET @ID = NULL

SELECT TOP 1 @SchemaName = SchemaName, @TableName = TableName, @IndexName = IndexName, @ID = ID
FROM #IndexBreakDown
WHERE IsProcessed = 0

INSERT INTO #DropIndex
        ( Script )
SELECT 'IF EXISTS ( SELECT 1 FROM sys.sysindexes WHERE name = '''+ @IndexName + ''' )
BEGIN
    DROP INDEX ' + @IndexName + ' ON ' + @SchemaName + '.' + @TableName
	+ ' PRINT ''- Index [' + @IndexName + '] Dropped''; 
END;'

UPDATE #IndexBreakDown
SET IsProcessed = 1
WHERE ID = @ID

SET @NewProcessCount = (SELECT COUNT(1) FROM #IndexBreakDown WHERE IsProcessed = 0)

END

SELECT  Script
FROM    #IndexScript;

SELECT Script
FROM #DropIndex