# pgrouting_app
Instalaion notes
1. Instal PostgreSQL server (tested on version 15)
2. Create database webapp
3. Restore app_db.backup
4. Edit app_server_pg_featureserv/config/pg_fetureserv.toml file Aand insert valid user and password for postgresql database at row:
DbConnection = "postgresql://user:password@localhost/webapp"
5. Start pg_featureserv.exe
6. Open file index.html in the internet browser
