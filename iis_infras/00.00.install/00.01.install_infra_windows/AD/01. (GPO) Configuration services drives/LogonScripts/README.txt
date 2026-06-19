=============================================================================
PROJET : MAPPAGE RESEAU UNIVERSEL
AUTEUR : Driss BENELKAID - optimedit.fr@gmail.com
DATE   : 28/12/2025
=============================================================================

--- DESCRIPTION ---
Ce pack contient deux scripts (PowerShell et Batch) permettant de monter 
les lecteurs reseau en fonction des droits partages reels des utilisateurs.

--- INSTRUCTIONS DE DEPLOIEMENT ---
1. Section "A ADAPTER POUR AUTRE CLIENT" :
   Modifier le nom du serveur et la liste des lecteurs dans le script choisi.

2. Emplacement :
   Copier le script sur le controleur de domaine dans :
   \\NOM-DU-SERVEUR\NETLOGON\

3. GPO :
   Assigner le script via : Configuration utilisateur > Parametres Windows 
   > Scripts (ouverture de session).

--- TEST ---
Par defaut, les scripts ouvrent le fichier log dans le Bloc-notes a la fin.
Une fois les tests valides, commentez la derniere ligne (notepad) avant
le deploiement general.

--- LOGS ---
Le fichier log est genere dans : %TEMP%\LogonDrives_OptimedIt.log
=============================================================================