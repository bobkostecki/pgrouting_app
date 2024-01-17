--Listings 1.0 Network preparation
--Listing 1.1 uploading extensions to databse

CREATE EXTENSION pgrouting CASCADE;

--Import road data to database using PostGIS Shapefile Import/Export Manager 
--Listing 1.2 transforming spatial reference of imported data to local geodetic system

ALTER TABLE osm_roads
ALTER COLUMN geom 
TYPE Geometry(linestring, 2180) 
USING ST_Transform(geom, 2180);

--Listing 1.3 creating conatiner schema gis for network data
DROP SCHEMA gis CASCADE;
CREATE SCHEMA gis;

--Listing 1.4 Creating table with polygon of network range
CREATE TABLE gis.networkrange AS 
SELECT 'range' AS name ,st_union(geom)::geometry(polygon,2180) AS geom 
FROM powiaty WHERE jpt_nazwa_ IN ('powiat Poznań', 'powiat poznański')

--Listing 1.5 Creating table with filtered roads regarding road type and range of network
CREATE TABLE gis.roads AS 
WITH g AS 
(SELECT st_union(geom) AS geom FROM powiaty where jpt_nazwa_ in ('powiat Poznań', 'powiat poznański' ))
SELECT r.* AS geom FROM osm_roads r join g 
ON st_contains(g.geom, r.geom) where maxspeed <= 90 
and fclass not in ('bridleway','footway', 'steps', 'path', 'busway', 'service','pedestrian');
alter table gis.roads add primary key (gid);


--Listing 1.5.1 handling multi-level junctions 
alter table gis.roads
add column bridge_tunnel boolean;
update gis.roads
set bridge_tunnel = (
SELECT
CASE
 WHEN bridge='T' THEN true
 WHEN tunnel='T' THEN true
ELSE
 false
END);


--Listing 1.6 table creating with edges up to 50m
CREATE TABLE gis.roads_50 AS
SELECT row_number() OVER (ORDER BY gid asc)AS gid,gid AS old_id, ST_LineSubstring(geom, 50.00*n/length,
  CASE
	WHEN 50.00*(n+1) < length THEN 50.00*(n+1)/length
	ELSE 1
  END) ::geometry(linestring,2180) As geom 
FROM
  (SELECT roads.gid,
  ST_LineMerge(roads.geom) AS geom, --st_linemerge in the case connected multilines
  ST_Length(roads.geom) As length
  FROM gis.roads
  ) AS t
CROSS JOIN generate_series(0,10000) AS n
WHERE n*50.00/length < 1;

--Listing 1.7 Query performing correction of the net topology 
SELECT pgr_nodeNetwork('gis.roads_50', 0.01, 'gid', 'geom',rows_where:= 'bridge_tunnel= false', outall:=true );

--Listing 1.8 Query adding cost column to netowrk table
ALTER TABLE gis.roads_50_noded ADD COLUMN length double precision;
UPDATE gis.roads_50_noded SET length = ST_Length(geom);

--Listing 1.9 Query responsible for topology creation
SELECT pgr_createTopology('gis.roads_50_noded', 0.01,'geom','id');



--Listing 1.10 Query peforming topology analysis
SELECT pgr_analyzeGraph('gis.roads_50_noded', 0.01,'geom','id');

--Listing 1.11 Queries adding optional parameters with values
ALTER TABLE gis.roads_50_noded
ADD COLUMN x1 double precision,
ADD COLUMN y1 double precision,
ADD COLUMN x2 double precision,
ADD COLUMN y2 double precision;

UPDATE gis.roads_50_noded
SET x1 = st_x(st_startpoint(geom)),
    y1 = st_y(st_startpoint(geom)),
    x2 = st_x(st_endpoint(geom)),
    y2 = st_y(st_endpoint(geom));
	
--Listings 2.0 testing and code of wrapper functions 
--Listing 2.1 Queries testing algorithms pgr_dijkstra and pgr_aStar
SELECT * FROM pgr_dijkstra(
'SELECT id, source::INTEGER, target::bigint,
length::double precision AS cost
FROM gis.roads_50_noded',1852,2135,false)

SELECT * FROM pgr_aStar(
'SELECT id, source::INTEGER, target::bigint,
length::double precision AS cost,x1,y1,x2,y2
FROM gis.roads_50_noded',1852,2135,false
);

--Listing 2.2 testing pgr_dijkstra with geometry
SELECT seq, node, edge,cost,agg_cost,geom 
FROM pgr_dijkstra('SELECT id,
source::integer, target::integer,
length::double precision AS cost
FROM gis.roads_50_noded',1852,2135, false)AS di
join gis.roads_50_noded pt ON di.edge=pt.id;



--Listing 2.3 wrapper with wgs points coordinates
CREATE OR REPLACE FUNCTION gis.wrapxy_dijkstrawgs(
	x1 double precision,
	y1 double precision,
	x2 double precision,
	y2 double precision)
returns table (seq integer, cost double precision, geom geometry)
AS
$$
WITH dijkstra AS (
SELECT * FROM pgr_dijkstra('SELECT id,
source::integer, target::integer, 
length::double precision AS cost
FROM gis.roads_50_noded',
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||$1||' '||$2||')',4326),2180) LIMIT 1), 
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||$3||' '||$4||')',4326),2180) LIMIT 1),
false))
SELECT dijkstra.seq, dijkstra.cost,
        CASE
            WHEN dijkstra.node = pt.source THEN geom
            ELSE ST_Reverse(geom)
        END AS route_geom
        FROM dijkstra join gis.roads_50_noded pt
	on dijkstra.edge=pt.id;
$$
LANGUAGE 'sql';

--Listing 2.4 Query performing wrapxy_dijkstrawgs wrapper tests with example coordinates
SELECT * FROM gis.wrapxy_dijkstrawgs(16.78, 52.34, 15.80, 52.37);
SELECT (sum(cost)/1000)::numeric(6,2) AS dlugosc_km,  
st_makeline(route.geom) FROM(
SELECT * FROM
gis.wrapxy_dijkstrawgs(16.78, 52.34, 15.80, 52.37) ORDER BY seq)AS route;

--Listing 2.5 Wrapper function of pgr_dikstravia
CREATE OR REPLACE FUNCTION gis.wrapxy_dijkstravia(
x1 double precision,y1 double precision,
x2 double precision,y2 double precision,
x3 double precision,y3 double precision
)
returns table (seq integer, cost double precision, geom geometry)
AS
$$
WITH dijkstra AS (
SELECT * FROM pgr_dijkstravia('SELECT id,
source::integer, target::integer, 
length::double precision AS cost
FROM gis.roads_50_noded',ARRAY[
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||$1||' '||$2||')',4326),2180) LIMIT 1), 
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||$3||' '||$4||')',4326),2180) LIMIT 1),
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||$5||' '||$6||')',4326),2180) LIMIT 1)	
],false))

SELECT dijkstra.seq, dijkstra.cost,
        CASE
            WHEN dijkstra.node = pt.source THEN geom
            ELSE ST_Reverse(geom)
        END AS route_geom
        FROM dijkstra join gis.roads_50_noded pt
	on dijkstra.edge=pt.id;
$$
LANGUAGE 'sql';

--Listing 2.6 Testing query of dijkstravia wrapper function with example coordinates
SELECT * FROM gis.wrapxy_dijkstravia(17.36, 52.25, 17.28, 52.20,17.42,52.12);


--Listing 2.7 Code of alphAShape wrapper function 

CREATE OR REPLACE FUNCTION gis.alphAShape(x double precision, y double precision, dim integer)
returns table (geom geometry) AS
$$
WITH dd AS (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target, length::double precision AS cost
FROM gis.roads_50_noded',
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||x||' '||y||')',4326),2180) LIMIT 1),
dim, false)
)
SELECT ST_ConcaveHull(st_collect(the_geom),0.1) AS geom
FROM gis.roads_50_noded_vertices_pgr net
INNER JOIN dd ON net.id=dd.node;
$$
LANGUAGE 'sql';


CREATE OR REPLACE FUNCTION gis.alphAShape(x double precision, y double precision, dim integer)
returns table (geom geometry) AS
$$
WITH dd AS (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target, length::double precision AS cost
FROM gis.roads_50_noded',
(SELECT id::integer FROM gis.roads_50_noded_vertices_pgr
ORDER BY the_geom <-> ST_Transform(ST_GeometryFromText('POINT('||x||' '||y||')',4326),2180) LIMIT 1),
dim, false)
)
SELECT pgr_AlphaShape(st_collect(the_geom)) AS geom
FROM gis.roads_50_noded_vertices_pgr net
INNER JOIN dd ON net.id=dd.node;
$$
LANGUAGE 'sql';

--Listing 2.7  Query testing alphAShape function with exmaple parameters
SELECT * FROM gis.alphAShape( 16.94,52.36,3000);

--Listing 2.8 Query testing alphAShape function with multiple distances
SELECT n, gis.alphAShape( 16.9,52.4,n)geom
FROM 
generate_series(1000,6000,1000)n ORDER BY n desc ;

--Listings 3.0 web development
--Listing 3.1  Creation schema required for pg_featureserv
CREATE SCHEMA postgisftw;

--3.2 Code of makealphAShape function required for pg_featureserv
CREATE OR REPLACE FUNCTION postgisftw.makealphAShape( 
      x double precision DEFAULT 16.94, 
	  y double precision DEFAULT 52.36,
	  dim integer DEFAULT 1500 ) 
RETURNS TABLE(geom geometry) 
AS $$ 
BEGIN 
     RETURN QUERY 
           SELECT 
           t.geom 
    FROM gis.alphAShape(x,y,dim) t; 
END; 
$$ 
LANGUAGE 'plpgsql' STABLE;

--Listing 3.3 query testing makealphAShape function 
SELECT geom FROM postgisftw.makealphAShape();

--Listing 3.4 Code of fromatob function required for pg_featureserv handling wrapper wrapxy_dijkstrawgs
CREATE OR REPLACE FUNCTION postgisftw.fromatob( 
      x1 double precision DEFAULT 0, 
	  y1 double precision DEFAULT 0,
	  x2 double precision DEFAULT 0, 
	  y2 double precision DEFAULT 0
	  ) 
RETURNS TABLE(len_km numeric(6,2), geom geometry) 
AS $$ 
BEGIN 
RETURN QUERY 
	SELECT (sum(cost)/1000)::numeric(6,2) AS len_km,
	st_transform(st_makeline(route.geom),4326) AS geom
	FROM (SELECT * FROM
	gis.wrapxy_dijkstrawgs(x1, y1, x2, y2)
	ORDER BY seq)AS route;
END; 
$$ 
LANGUAGE 'plpgsql' STABLE;

--Listing 3.5 query testing FROMatob function with example points coordinates
SELECT * FROM postgisftw.fromatob(16.3549,53.1804,16.3844,53.1560);

--Listing 3.6 function pg_featureserv handling wrapper wrapxy_dijkstrawgs
CREATE OR REPLACE FUNCTION postgisftw.fromatobvia( 
      x1 double precision DEFAULT 0, 
	  y1 double precision DEFAULT 0,
	  x2 double precision DEFAULT 0, 
	  y2 double precision DEFAULT 0,
	  x3 double precision DEFAULT 0, 
	  y3 double precision DEFAULT 0
	   ) 
RETURNS TABLE(len_km numeric(6,2), geom geometry) 
AS $$ 
BEGIN 
RETURN QUERY 
	SELECT (sum(cost)/1000)::numeric(6,2) AS len_km,
	st_transform(st_makeline(route.geom),4326) AS geom
	FROM (SELECT * FROM
	gis.wrapxy_dijkstravia(x1, y1, x2, y2, x3, y3)
	ORDER BY seq)AS route;
END; 
$$ 
LANGUAGE 'plpgsql' STABLE; 

--Listing 3.7 Query testing  function fromatobvia with example points coordinates
SELECT * FROM postgisftw.fromatobvia(16.94675445556641,
									52.435920583590125,
									 16.884269714355472,
									 52.40220940824191,
									16.95121765136719,
									52.38398208257353);

