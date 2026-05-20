-- ============================================================
--  DEVOIR ETL - TIA_ETL Data Warehouse
--  Source      : AdventureWorks2022 (SQL Server)
--  Destination : TIA_ETL
--  Auteur      : HATHOUTI Mohammed Taha, JIDAL Ilyas, KABORE Mohammad Sharif Jonathan
--  Cours       : Ing3-BIDwH-25/26 S6 - Pr A.RiadSolh
-- ============================================================
--
--  Convention calendrier fiscal :
--    L'annee fiscale commence le 1er lundi de mars de chaque
--    annee calendaire et se termine le dimanche precedant le
--    1er lundi de mars de l'annee suivante.
--    Hypothese : DATEFIRST 1 (lundi = 1er jour de semaine).
--
--  Pour executer : lancez ce script dans sa totalite.
--  Il (re)cree la base TIA_ETL, toutes les tables et charge
--  toutes les donnees.
-- ============================================================

SET DATEFIRST 1;      -- Lundi = 1
SET NOCOUNT ON;
GO

-- ============================================================
--  PARTIE 1 : CREATION DE LA BASE DE DONNEES
-- ============================================================

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TIA_ETL')
BEGIN
    ALTER DATABASE TIA_ETL SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TIA_ETL;
END
GO

CREATE DATABASE TIA_ETL;
GO

USE TIA_ETL;
GO

PRINT '>>> Base TIA_ETL creee.';
GO

-- ============================================================
--  PARTIE 2 : CREATION DES TABLES  (DDL hors procedures)
-- ============================================================

-- ----------------------------------------------------------
--  dim_date : dimension calendrier (01/01/2010 - 31/12/2020)
-- ----------------------------------------------------------
CREATE TABLE dim_date (
    date_id          INT          NOT NULL,   -- YYYYMMDD
    date_value       DATETIME     NOT NULL,
    month_num        TINYINT      NOT NULL,   -- 1..12
    month_name       VARCHAR(20)  NOT NULL,   -- 'January'..'December'
    quarter_num      TINYINT      NOT NULL,   -- 1..4
    quarter_name     CHAR(2)      NOT NULL,   -- 'Q1'..'Q4'
    year_num         SMALLINT     NOT NULL,
    month_year       VARCHAR(10)  NOT NULL,   -- ex. '2010-1'
    quarter_year     VARCHAR(10)  NOT NULL,   -- ex. '2010-Q1'
    fiscal_year      SMALLINT     NOT NULL,
    fiscal_week      SMALLINT     NOT NULL,   -- 1..53
    fiscal_year_week VARCHAR(10)  NOT NULL,   -- ex. '2010-1'
    CONSTRAINT PK_dim_date PRIMARY KEY (date_id)
);
GO

-- ----------------------------------------------------------
--  dim_product : dimension produit
-- ----------------------------------------------------------
CREATE TABLE dim_product (
    product_id       INT           NOT NULL,
    product_name     NVARCHAR(50)  NOT NULL,
    product_number   NVARCHAR(25)  NOT NULL,
    color            NVARCHAR(15)  NULL,
    standard_cost    MONEY         NOT NULL,
    list_price       MONEY         NOT NULL,
    style            NVARCHAR(5)   NULL,
    subcategory_name NVARCHAR(50)  NULL,
    category_name    NVARCHAR(50)  NULL,
    CONSTRAINT PK_dim_product PRIMARY KEY (product_id)
);
GO

-- ----------------------------------------------------------
--  dim_age_group : tranche d'age des clients
-- ----------------------------------------------------------
CREATE TABLE dim_age_group (
    age_group_id    INT          NOT NULL,
    age_group_label VARCHAR(30)  NOT NULL,
    age_min         INT          NULL,   -- NULL = pas de borne basse
    age_max         INT          NULL,   -- NULL = pas de borne haute
    CONSTRAINT PK_dim_age_group PRIMARY KEY (age_group_id)
);
GO

-- ----------------------------------------------------------
--  fact_sales : fait transactionnel (jour x produit x age)
-- ----------------------------------------------------------
CREATE TABLE fact_sales (
    date_id        INT    NOT NULL,
    product_id     INT    NOT NULL,
    age_group_id   INT    NOT NULL,
    total_quantity INT    NOT NULL,
    total_amount   MONEY  NOT NULL,
    CONSTRAINT PK_fact_sales
        PRIMARY KEY (date_id, product_id, age_group_id),
    CONSTRAINT FK_fact_sales_date
        FOREIGN KEY (date_id)      REFERENCES dim_date(date_id),
    CONSTRAINT FK_fact_sales_product
        FOREIGN KEY (product_id)   REFERENCES dim_product(product_id),
    CONSTRAINT FK_fact_sales_age
        FOREIGN KEY (age_group_id) REFERENCES dim_age_group(age_group_id)
);
GO

-- ----------------------------------------------------------
--  fact_monthly_sales : fait agrege mensuel (mois x produit)
--  Alimente via MERGE pour supporter les chargements partiels
--  en cours de mois.
-- ----------------------------------------------------------
CREATE TABLE fact_monthly_sales (
    date_id        INT    NOT NULL,   -- date_id du 1er jour du mois
    product_id     INT    NOT NULL,
    total_quantity INT    NOT NULL,
    order_count    INT    NOT NULL,   -- nb de commandes distinctes
    total_amount   MONEY  NOT NULL,
    CONSTRAINT PK_fact_monthly_sales
        PRIMARY KEY (date_id, product_id),
    CONSTRAINT FK_fact_monthly_date
        FOREIGN KEY (date_id)    REFERENCES dim_date(date_id),
    CONSTRAINT FK_fact_monthly_product
        FOREIGN KEY (product_id) REFERENCES dim_product(product_id)
);
GO

PRINT '>>> Tables creees.';
GO

-- ============================================================
--  PARTIE 3 : PROCEDURES ETL
-- ============================================================

-- ----------------------------------------------------------
--  3.1  etl_load_dim_date
--       Genere toutes les dates du 01/01/2010 au 31/12/2020
--       avec attributs calendaires et fiscaux.
-- ----------------------------------------------------------
CREATE OR ALTER PROCEDURE etl_load_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;

    -- Suppression dans l'ordre inverse des FK
    DELETE FROM fact_monthly_sales;
    DELETE FROM fact_sales;
    DELETE FROM dim_date;

    -- Precalcul du 1er lundi de mars pour les annees 2009..2021
    -- Formule : offset = (8 - DATEPART(WEEKDAY, 1er mars)) % 7
    --   => ajoute 0 si 1er mars est deja lundi, sinon saute au lundi suivant
    WITH FiscalStarts AS (
        SELECT y, DATEADD(
        		DAY,
        		(8 - DATEPART(WEEKDAY, DATEFROMPARTS(y, 3, 1))) % 7,
        		DATEFROMPARTS(y, 3, 1))
        AS fs
        
        FROM (VALUES
            (2009),(2010),(2011),(2012),(2013),(2014),(2015),
            (2016),(2017),(2018),(2019),(2020),(2021)
        ) v(y)
    ),

    -- Serie de dates par CTE recursive
    DateSeries AS (
        SELECT CAST('2010-01-01' AS DATE) AS d
        UNION ALL
        SELECT DATEADD(DAY, 1, d)
        FROM DateSeries
        WHERE d < '2020-12-31'
    ),

    -- Calcul de l'annee fiscale et de la date de debut de l'annee fiscale
    DateFiscal AS (
        SELECT
            d,
            YEAR(d)  AS yr,
            MONTH(d) AS mo,
            CASE
                WHEN d >= (SELECT fs FROM FiscalStarts WHERE y = YEAR(d))
                THEN YEAR(d)
                ELSE YEAR(d) - 1
            END AS fiscal_yr,
            CASE
                WHEN d >= (SELECT fs FROM FiscalStarts WHERE y = YEAR(d))
                THEN (SELECT fs FROM FiscalStarts WHERE y = YEAR(d))
                ELSE (SELECT fs FROM FiscalStarts WHERE y = YEAR(d) - 1)
            END AS fiscal_start
        FROM DateSeries
    )

    INSERT INTO dim_date (
        date_id, date_value,
        month_num, month_name,
        quarter_num, quarter_name,
        year_num,
        month_year, quarter_year,
        fiscal_year, fiscal_week, fiscal_year_week
    )
    SELECT
        YEAR(d)*10000 + MONTH(d)*100 + DAY(d)           AS date_id,
        CAST(d AS DATETIME)                              AS date_value,
        mo                                               AS month_num,
        DATENAME(MONTH, d)                               AS month_name,
        (mo - 1) / 3 + 1                                AS quarter_num,
        'Q' + CAST((mo - 1) / 3 + 1 AS CHAR(1))        AS quarter_name,
        yr                                               AS year_num,
        CAST(yr AS VARCHAR(4)) + '-' + CAST(mo AS VARCHAR(2))
                                                         AS month_year,
        CAST(yr AS VARCHAR(4)) + '-Q'
            + CAST((mo - 1) / 3 + 1 AS CHAR(1))        AS quarter_year,
        fiscal_yr                                        AS fiscal_year,
        DATEDIFF(DAY, fiscal_start, d) / 7 + 1          AS fiscal_week,
        CAST(fiscal_yr AS VARCHAR(4)) + '-'
            + CAST(DATEDIFF(DAY, fiscal_start, d) / 7 + 1 AS VARCHAR(3))
                                                         AS fiscal_year_week
    FROM DateFiscal
    OPTION (MAXRECURSION 5000);

    PRINT '    dim_date : ' + CAST(@@ROWCOUNT AS VARCHAR) + ' lignes chargees.';
END;
GO

-- ----------------------------------------------------------
--  3.2  etl_load_dim_product
--       Charge tous les produits depuis AdventureWorks2022
-- ----------------------------------------------------------
CREATE OR ALTER PROCEDURE etl_load_dim_product
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dim_product;

    INSERT INTO dim_product (
        product_id, product_name, product_number,
        color, standard_cost, list_price, style,
        subcategory_name, category_name
    )
    SELECT
        p.ProductID,
        p.Name,
        p.ProductNumber,
        p.Color,
        p.StandardCost,
        p.ListPrice,
        RTRIM(p.Style),
        ps.Name  AS subcategory_name,
        pc.Name  AS category_name
    FROM AdventureWorks2022.Production.Product p
    LEFT JOIN AdventureWorks2022.Production.ProductSubcategory ps
           ON p.ProductSubcategoryID = ps.ProductSubcategoryID
    LEFT JOIN AdventureWorks2022.Production.ProductCategory pc
           ON ps.ProductCategoryID = pc.ProductCategoryID;

    PRINT '    dim_product : ' + CAST(@@ROWCOUNT AS VARCHAR) + ' lignes chargees.';
END;
GO

-- ----------------------------------------------------------
--  3.3  etl_load_dim_age_group
--       Insere les 4 tranches d'age statiques
-- ----------------------------------------------------------
CREATE OR ALTER PROCEDURE etl_load_dim_age_group
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dim_age_group;

    INSERT INTO dim_age_group (age_group_id, age_group_label, age_min, age_max)
    VALUES
        (1, '-25 ans',        NULL, 24),
        (2, '25-34 ans',      25,   34),
        (3, '35-44 ans',      35,   44),
        (4, '45 ans et plus', 45,   NULL);

    PRINT '    dim_age_group : 4 lignes chargees.';
END;
GO

-- ----------------------------------------------------------
--  3.4  etl_load_facts
--       Charge fact_sales et fact_monthly_sales depuis la
--       meme source de donnees via MERGE (upsert).
--
--       Source : ventes aux clients particuliers
--                (PersonID IS NOT NULL, StoreID IS NULL)
--                OrderDate dans [2010-01-01, 2020-12-31]
--
--       fact_sales granularite : jour x produit x tranche_age
--       fact_monthly_sales     : mois x produit  (1er jour du mois)
-- ----------------------------------------------------------
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE etl_load_facts
AS
BEGIN
    SET NOCOUNT ON;
    SET DATEFIRST 1;

    -- -------------------------------------------------------
    --  Table temporaire : source commune des deux facts
    --  Strategie : CROSS APPLY extrait BirthDate une seule
    --  fois ; un sous-SELECT calcule l'age exact ; le SELECT
    --  externe mappe age -> age_group_id.
    -- -------------------------------------------------------
    IF OBJECT_ID('tempdb..#SalesKeyed') IS NOT NULL
        DROP TABLE #SalesKeyed;

    SELECT
        date_id,
        month_date_id,
        SalesOrderID,
        ProductID,
        OrderQty,
        LineTotal,
        CASE
            WHEN age < 25  THEN 1
            WHEN age <= 34 THEN 2
            WHEN age <= 44 THEN 3
            ELSE 4
        END AS age_group_id
    INTO #SalesKeyed
    FROM (
        SELECT
            YEAR(soh.OrderDate)*10000
            + MONTH(soh.OrderDate)*100
            + DAY(soh.OrderDate)              AS date_id,
            YEAR(soh.OrderDate)*10000
            + MONTH(soh.OrderDate)*100
            + 1                               AS month_date_id,
            soh.SalesOrderID,
            sod.ProductID,
            sod.OrderQty,
            sod.LineTotal,
            -- Age exact a la date de commande
            DATEDIFF(YEAR, bd.BirthDate, soh.OrderDate)
            - CASE
                WHEN MONTH(bd.BirthDate) > MONTH(soh.OrderDate)
                  OR (MONTH(bd.BirthDate) = MONTH(soh.OrderDate)
                     AND DAY(bd.BirthDate) > DAY(soh.OrderDate))
                THEN 1 ELSE 0
              END                             AS age
        FROM AdventureWorks2022.Sales.SalesOrderHeader soh
        JOIN AdventureWorks2022.Sales.Customer c
            ON soh.CustomerID = c.CustomerID
           AND c.PersonID IS NOT NULL
           AND c.StoreID IS NULL
        JOIN AdventureWorks2022.Sales.SalesOrderDetail sod
            ON soh.SalesOrderID = sod.SalesOrderID
        -- CROSS APPLY extrait la date de naissance XML une seule fois
        CROSS APPLY (
            SELECT CAST(pp.Demographics.value(
                'declare namespace n="http://schemas.microsoft.com/sqlserver/2004/07/adventure-works/IndividualSurvey";
                 (/n:IndividualSurvey/n:BirthDate)[1]',
                'date') AS DATE) AS BirthDate
            FROM AdventureWorks2022.Person.Person pp
            WHERE pp.BusinessEntityID = c.PersonID
        ) bd
        WHERE soh.OrderDate >= '2010-01-01'
          AND soh.OrderDate <  '2021-01-01'
    ) sub;

    -- -------------------------------------------------------
    --  Chargement fact_sales via MERGE
    --  Granularite : (date_id, product_id, age_group_id)
    -- -------------------------------------------------------
    MERGE INTO fact_sales AS tgt
    USING (
        SELECT
            date_id,
            ProductID     AS product_id,
            age_group_id,
            SUM(OrderQty)   AS total_quantity,
            SUM(LineTotal)  AS total_amount
        FROM #SalesKeyed
        GROUP BY date_id, ProductID, age_group_id
    ) AS src
    ON  tgt.date_id      = src.date_id
    AND tgt.product_id   = src.product_id
    AND tgt.age_group_id = src.age_group_id
    WHEN MATCHED THEN
        UPDATE SET
            total_quantity = src.total_quantity,
            total_amount   = src.total_amount
    WHEN NOT MATCHED THEN
        INSERT (date_id, product_id, age_group_id, total_quantity, total_amount)
        VALUES (src.date_id, src.product_id, src.age_group_id,
                src.total_quantity, src.total_amount);

    PRINT '    fact_sales charge.';

    -- -------------------------------------------------------
    --  Chargement fact_monthly_sales via MERGE
    --  Granularite : (month_date_id, product_id)
    --  Supporte les chargements partiels en cours de mois.
    -- -------------------------------------------------------
    MERGE INTO fact_monthly_sales AS tgt
    USING (
        SELECT
            month_date_id              AS date_id,
            ProductID                  AS product_id,
            SUM(OrderQty)              AS total_quantity,
            COUNT(DISTINCT SalesOrderID) AS order_count,
            SUM(LineTotal)             AS total_amount
        FROM #SalesKeyed
        GROUP BY month_date_id, ProductID
    ) AS src
    ON  tgt.date_id    = src.date_id
    AND tgt.product_id = src.product_id
    WHEN MATCHED THEN
        UPDATE SET
            total_quantity = src.total_quantity,
            order_count    = src.order_count,
            total_amount   = src.total_amount
    WHEN NOT MATCHED THEN
        INSERT (date_id, product_id, total_quantity, order_count, total_amount)
        VALUES (src.date_id, src.product_id,
                src.total_quantity, src.order_count, src.total_amount);

    PRINT '    fact_monthly_sales charge.';

    DROP TABLE #SalesKeyed;
END;
GO

PRINT '>>> Procedures ETL creees.';
GO

-- ============================================================
--  PARTIE 4 : EXECUTION DE L ETL
-- ============================================================

PRINT '--- Chargement dim_date ...';
EXEC etl_load_dim_date;

PRINT '--- Chargement dim_product ...';
EXEC etl_load_dim_product;

PRINT '--- Chargement dim_age_group ...';
EXEC etl_load_dim_age_group;

PRINT '--- Chargement facts ...';
EXEC etl_load_facts;
GO

-- ============================================================
--  PARTIE 5 : VERIFICATION
-- ============================================================

PRINT '';
PRINT '=== BILAN DES CHARGEMENTS ===';

SELECT
    'dim_date'          AS [Table], COUNT(*) AS [Lignes] FROM dim_date
UNION ALL SELECT 'dim_product',        COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_age_group',      COUNT(*) FROM dim_age_group
UNION ALL SELECT 'fact_sales',         COUNT(*) FROM fact_sales
UNION ALL SELECT 'fact_monthly_sales', COUNT(*) FROM fact_monthly_sales;
GO

-- Controles rapides
PRINT '--- Exemple dim_date (fiscal year 2012) ---';
SELECT TOP 5
    date_id, date_value, month_name, quarter_name,
    year_num, fiscal_year, fiscal_week, fiscal_year_week
FROM dim_date
WHERE date_value >= '2012-03-01' AND date_value <= '2012-03-15'
ORDER BY date_id;
GO

PRINT '--- Exemple fact_sales ---';
SELECT TOP 5
    fs.date_id,
    dd.date_value,
    dp.product_name,
    dag.age_group_label,
    fs.total_quantity,
    fs.total_amount
FROM fact_sales fs
JOIN dim_date      dd  ON fs.date_id      = dd.date_id
JOIN dim_product   dp  ON fs.product_id   = dp.product_id
JOIN dim_age_group dag ON fs.age_group_id = dag.age_group_id
ORDER BY fs.date_id;
GO

PRINT '--- Exemple fact_monthly_sales ---';
SELECT TOP 5
    fms.date_id,
    dd.month_year,
    dp.product_name,
    fms.total_quantity,
    fms.order_count,
    fms.total_amount
FROM fact_monthly_sales fms
JOIN dim_date    dd ON fms.date_id    = dd.date_id
JOIN dim_product dp ON fms.product_id = dp.product_id
ORDER BY fms.date_id;
GO

PRINT '>>> ETL termine avec succes.';
GO
