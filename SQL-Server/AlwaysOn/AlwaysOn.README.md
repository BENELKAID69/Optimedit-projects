<div align="center">

# 🗄️ SQL Server 2022 - Always On Availability Groups & Session State

**Infrastructure hautement disponible pour 13 applications IIS (Web Farm ARR)**
**Haute Disponibilité · TDE (Chiffrement au repos) · Kerberos · Session State SQL**

[![SQL Server](https://img.shields.io/badge/SQL_Server-2022_Developer-CC2927?style=flat-square&logo=microsoftsqlserver&logoColor=white)](https://www.microsoft.com/en-us/sql-server/)
[![Windows Server](https://img.shields.io/badge/Windows_Server-2022%2F2025-0078D6?style=flat-square&logo=windowsserver&logoColor=white)](https://www.microsoft.com/)
[![Always On](https://img.shields.io/badge/Always_On-Availability_Group-success?style=flat-square&logo=microsoftsqlserver&logoColor=white)](https://learn.microsoft.com/en-us/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
[![TDE](https://img.shields.io/badge/Security-TDE_Encryption-orange?style=flat-square)](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption)
[![Ansible](https://img.shields.io/badge/Ansible-Automation-red?style=flat-square&logo=ansible&logoColor=white)](https://www.ansible.com/)
[![IIS](https://img.shields.io/badge/IIS-Session_State-blue?style=flat-square&logo=iis&logoColor=white)](https://www.iis.net/)

</div>

---

## 📌 Présentation du projet

Ce dépôt centralise l'ensemble de la documentation technique, des scripts PowerShell (WinRM/Ansible) et des playbooks Ansible pour le déploiement et la maintenance d'une architecture **SQL Server 2022 Always On** à deux nœuds (`SQLS01` et `SQLS02`). 

Cette infrastructure a pour but de fournir une base de données **hautement disponible et résiliente** (RTO et RPO proches de zéro) pour alimenter les **13 applications métiers** hébergées sur 6 serveurs IIS (`OPT-IIS-01` à `06`), derrière un Reverse Proxy ARR (`OPT-RP-01`).

---

## 🏗️ Topologie & Architecture

Le diagramme ci-dessous illustre le flux de données, le cluster Always On, et l'intégration avec la Web Farm IIS pour la persistance des sessions.

```mermaid
flowchart TD
    %% =========================================================
    %% DÉFINITION DES STYLES
    %% =========================================================
    classDef internet fill:#ffe6e6,stroke:#cc0000,stroke-width:2px,color:#000;
    classDef proxy fill:#e6f2ff,stroke:#0066cc,stroke-width:2px,color:#000;
    classDef web fill:#fff2e6,stroke:#ff8000,stroke-width:2px,color:#000;
    classDef sql fill:#e6f9e6,stroke:#2eb82e,stroke-width:2px,color:#000;
    classDef listener fill:#e6f2ff,stroke:#0066cc,stroke-width:2px,color:#000;
    classDef cno fill:#ffffff,stroke:#666666,stroke-width:2px,stroke-dasharray: 5 5,color:#000;
    classDef ad fill:#f2e6ff,stroke:#8000cc,stroke-width:2px,color:#000;
    classDef fs fill:#f2f2f2,stroke:#666666,stroke-width:2px,color:#000;

    %% =========================================================
    %% BLOC 1 : Flux d'entrée & SSL (Horizontal)
    %% =========================================================
    subgraph Ligne1 ["1. Flux d'entrée & Chaîne de confiance SSL"]
        direction LR
        Internet(["🌐 Internet<br/>(Clients Web Publics)"]):::internet
        RP01["🛡️ OPT-RP-01<br/>(Reverse Proxy ARR)<br/>192.168.1.200"]:::proxy
        IIS_Farm["🖥️ OPT-IIS-01 à OPT-IIS-06<br/>(6 Serveurs Web)<br/>192.168.1.119 à .124"]:::web
        
        Internet ==>|"HTTPS (443)<br/>🔒 Certificat Public<br/>(SAN 13 sites)"| RP01
        RP01 ==>|"HTTPS (443)<br/>🔒 Certificat ADCS<br/>(SAN 13 sites)<br/>ARR Load Balancing"| IIS_Farm
    end

    %% =========================================================
    %% BLOC 2 : Infrastructure Backend (Horizontal)
    %% =========================================================
    subgraph Ligne2 ["2. Infrastructure Backend, Cluster & Données"]
        direction LR
        
        %% Sous-groupe SQL
        subgraph Cluster_SQL ["Cluster SQL Always On (WSFC)"]
            direction LR
            CNO["⚙️ CL-SQL-AG (CNO)<br/>192.168.1.253"]:::cno
            Listener{"🎧 SQL-AG-LSTNR<br/>(Listener)<br/>192.168.1.250"}:::listener
            SQL01[("🗄️ SQLS01 (Primaire)<br/>192.168.1.251")]:::sql
            SQL02[("🗄️ SQLS02 (Secondaire)<br/>192.168.1.252")]:::sql
            
            CNO -.->|"Gestion WSFC"| Listener
            Listener ==>|"Routage Actif"| SQL01
            SQL01 <==>|"Réplication Synchrone<br/>(TCP 5022)"| SQL02
        end

        %% Sous-groupe Infra
        subgraph Infra ["Services d'Infrastructure"]
            direction TB
            DC03(["🛡️ DC03<br/>(AD / DNS / ADCS)<br/>192.168.1.202"]):::ad
            FS03(["📁 OPT-FS03<br/>(Témoin FSW)<br/>192.168.1.201"]):::fs
        end
    end

    %% =========================================================
    %% CONNEXIONS ENTRE LES DEUX BLOCS (et inter-services)
    %% =========================================================
    IIS_Farm ==>|"SQL (TCP 1433)<br/>🔐 Kerberos"| Listener
    IIS_Farm -.->|"Kerberos (88)"| DC03

    SQL01 -.->|"Quorum (SMB 445)"| FS03
    SQL02 -.->|"Quorum (SMB 445)"| FS03
    SQL01 -.->|"Kerberos (88)"| DC03
    SQL02 -.->|"Kerberos (88)"| DC03

    %% Styles des liens
    linkStyle 0,1 stroke:#0066cc,stroke-width:2px;
    linkStyle 2 stroke:#2eb82e,stroke-width:2px;
    linkStyle 3 stroke:#2eb82e,stroke-width:2px;
    linkStyle 4,5 stroke:#2eb82e,stroke-width:1.5px,stroke-dasharray: 5 5;
    linkStyle 6,7,8,9 stroke:#8000cc,stroke-width:1.5px,stroke-dasharray: 3 3;