-- 6.2.0.add_databases_to_ag.sql
-- Objet  : Ajouter les 13 bases a l'Availability Group
-- Noeud  : SQLS01 (Primary)

ALTER AVAILABILITY GROUP [AG-OPTIMEDIT]
ADD DATABASE DB_Direction, DB_Comptabilite, DB_Paie, DB_RH, DB_CE,
DB_IT, DB_Production, DB_Formation, DB_Achat, DB_Commercial,
DB_Client, DB_Juridique, DB_Blog;
GO
