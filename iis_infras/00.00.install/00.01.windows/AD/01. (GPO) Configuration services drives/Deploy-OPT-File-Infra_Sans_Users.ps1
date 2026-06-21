<#
.SYNOPSIS
    Deploy-OPTFileInfra.ps1 - Version 5.2 (Production / Durcissement NTFS validé).
    Script d'automatisation et de déploiement global pour l'infrastructure d'identité,
    de stockage et de partage réseau de l'environnement optimedit.eu.

.DESCRIPTION
    Ce script centralisé est conçu pour être exécuté directement depuis un contrôleur de domaine 
    (ex: opt-dc02). Il orchestre de bout en bout l'approvisionnement des ressources logiques AD 
    et physiques du serveur de fichiers à distance (opt-fs02).

    Tâches exécutées de manière séquentielle :
    1. Validation d'environnement : Vérification de la présence du module ActiveDirectory et de la 
       connectivité réseau ICMP vers le serveur de fichiers cible.
    2. Modélisation Active Directory : Création récursive de l'arborescence des Unités Organisationnelles 
       (OU) sous la forme : _Entreprises -> OPT -> Groupes.
    3. Stratégie de sécurité AGDLP : Génération automatique des trois couches de groupes de sécurité 
       (Domaine Local 'GrL', Global 'GrG', Universel 'GrU') pour chaque service métier, suivi de l'imbrication 
       systématique des groupes globaux et universels dans leurs groupes locaux respectifs.
    4. Provisionnement du Stockage : Création à distance des répertoires physiques sur le volume ciblé (P:) 
       via les partages administratifs cachés (P$).
    5. Sécurisation NTFS Avancée (Droits Spéciaux) : Rupture stricte de l'héritage de sécurité sur chaque 
       racine de service. Injection des permissions immuables système (SYSTEM, Administrateurs, Admins du domaine). 
       Résolution universelle par SID du compte 'CREATOR OWNER' (S-1-3-0). Application fine des accès pour les 
       groupes de service via un découpage en deux ACEs distinctes (l'une pour la structure du conteneur, l'autre 
       déleguée pour les objets enfants) provoquant l'affichage des "Droits spéciaux" dans l'interface Windows.
    6. Exposition SMB : Création distante des partages réseau via l'infrastructure de gestion CIM/WMI, purge 
       des accès non sécurisés ("Tout le monde") et attribution des droits de partage exclusifs aux groupes locaux (GrL).

.PARAMETER Aucun
    Ce script ne prend aucun argument en entrée pour sécuriser son exécution. Les variables de cartographie 
    et de topologie réseau sont codées en dur dans les blocs d'initialisation de la fonction.

.INPUTS
    Aucun. Pas d'objets acceptés via le pipeline.

.OUTPUTS
    Sorties textuelles formatées dans la console PowerShell (Write-Host) traçant l'état d'avancement, 
    les créations d'objets, les assignations NTFS et le succès des configurations de partages SMB.

.NOTES
    AUTEUR       : Driss BENELKAID (Independent IT Consultant)
    ENTREPRISE   : optimedit.eu
    DATE         : 08/06/2026
    VERSION      : 5.2 
    HISTORIQUE   :
      - v1.0 à v3.0 : Scripts initiaux de tests d'arborescence locaux.
      - v4.0        : Version initiale acceptée (Correction des OUs imbriquées et variables dynamiques).
      - v5.0 à v5.1 : Isolation des SIDs universels pour la portabilité linguistique du Créateur Propriétaire.
      - v5.2 (Actuelle) : Implémentation du fractionnement des règles d'accès (Split ACE) pour forcer l'application 
                          des "Droits Spéciaux" NTFS sur les groupes locaux de service.

.EXAMPLE
    PS C:\> .\Deploy-OPTFileInfra.ps1
    Exécute l'intégralité du cycle de déploiement (OUs, Groupes AD, Arborescence NTFS, Droits Spéciaux et Partages SMB).
#>
# Argument GPO script d'ouverture de session -ExecutionPolicy Bypass -WindowStyle Hidden

function Invoke-InfraDeployment {
    [CmdletBinding()]
    param()

    process {
        # -----------------------------------------------------------------------------
        # 1. ENVIRONNEMENT & MODULES
        # -----------------------------------------------------------------------------
        if (!(Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-Error "Le module ActiveDirectory n'est pas installé sur ce serveur."
            return
        }
        Import-Module ActiveDirectory

        # -----------------------------------------------------------------------------
        # 2. CARTOGRAPHIE DES SERVICES
        # -----------------------------------------------------------------------------
        $Services = @(
            @{ Name = "Commun";       FolderName = "OPT_Commun" }
            @{ Name = "Direction";    FolderName = "OPT_Direction" }
            @{ Name = "Comptabilite"; FolderName = "OPT_Comptabilite" }
            @{ Name = "Paie";         FolderName = "OPT_Paie" }
            @{ Name = "RH";           FolderName = "OPT_RH" }
            @{ Name = "CE";           FolderName = "OPT_CE" }
            @{ Name = "IT";           FolderName = "OPT_IT" }
            @{ Name = "Production";   FolderName = "OPT_Production" }
            @{ Name = "Formation";    FolderName = "OPT_Formation" }
            @{ Name = "Achat";        FolderName = "OPT_Achat" }
            @{ Name = "Commercial";   FolderName = "OPT_Commercial" }
            @{ Name = "Client";       FolderName = "OPT_Client" }
            @{ Name = "Juridique";    FolderName = "OPT_Juridique" }
            @{ Name = "Blog";         FolderName = "OPT_Blog" }
            @{ Name = "Dev";          FolderName = "OPT_projets_optimedit\Dev" }
            @{ Name = "Marketing";    FolderName = "OPT_Marketing" }
            @{ Name = "Logistique";   FolderName = "OPT_Logistique" }
            @{ Name = "RD";           FolderName = "OPT_RD" }
        )

        # -----------------------------------------------------------------------------
        # 3. VARIABLES DE CONFIGURATION GLOBALE
        # -----------------------------------------------------------------------------
        $FileServer   = "opt-fs02"
        $LocalDrive   = "P"
        $RemotePath   = "\\$FileServer\$LocalDrive$"
        $DomainDN     = (Get-ADDomain).DistinguishedName
        $DomainName   = (Get-ADDomain).NetBIOSName

        # Validation de la connectivité réseau vers opt-fs02
        if (!(Test-Connection -ComputerName $FileServer -Count 1 -Quiet)) {
            Write-Error "Le serveur de fichiers cible [$FileServer] est injoignable. Arrêt du script."
            return
        }

        # -----------------------------------------------------------------------------
        # BLOC INITIALISATION : OU ARBORESCENCE
        # -----------------------------------------------------------------------------
        Write-Host "--- VALIDATION DE L'ARBORESCENCE DES OUs ---" -ForegroundColor Green
        $OUStructure = @("_Entreprises", "OPT", "Groupes")
        $CurrentParentDN = $DomainDN

        foreach ($OUName in $OUStructure) {
            $TargetOUCheck = "OU=$OUName,$CurrentParentDN"
            if (!(Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOUCheck'" -ErrorAction SilentlyContinue)) {
                Write-Host "Création de l'OU : $OUName" -ForegroundColor Cyan
                New-ADOrganizationalUnit -Name $OUName -Path $CurrentParentDN -ErrorAction Stop | Out-Null
            }
            $CurrentParentDN = $TargetOUCheck
        }
        $TargetOU = $CurrentParentDN

        # -----------------------------------------------------------------------------
        # ETAPE 1 : STRATEGIE DE GROUPES AD (AGDLP)
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 1 : STRATEGIE DE GROUPES AD ---" -ForegroundColor Green
        foreach ($Service in $Services) {
            $LocalGroup     = "OPT_GrL_$($Service.Name)"
            $GlobalGroup    = "OPT_GrG_$($Service.Name)"
            $UniversalGroup = "OPT_GrU_$($Service.Name)"

            if (!(Get-ADGroup -Filter "Name -eq '$GlobalGroup'")) {
                New-ADGroup -Name $GlobalGroup -GroupScope Global -GroupCategory Security -Path $TargetOU | Out-Null
            }
            if (!(Get-ADGroup -Filter "Name -eq '$UniversalGroup'")) {
                New-ADGroup -Name $UniversalGroup -GroupScope Universal -GroupCategory Security -Path $TargetOU | Out-Null
            }
            if (!(Get-ADGroup -Filter "Name -eq '$LocalGroup'")) {
                New-ADGroup -Name $LocalGroup -GroupScope DomainLocal -GroupCategory Security -Path $TargetOU | Out-Null
                Write-Host "Groupes créés pour le service : $($Service.Name)" -ForegroundColor Cyan
            }
            
            # Implémentation de la cascade AGDLP
            Add-ADGroupMember -Identity $LocalGroup -Members $GlobalGroup, $UniversalGroup -ErrorAction SilentlyContinue
        }

        # -----------------------------------------------------------------------------
        # ETAPE 2 : CREATION DES REPERTOIRES ET SECURISATION NTFS SPECIFIQUE
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 2 : CREATION DOSSIERS ET NTFS A DISTANCE ---" -ForegroundColor Green
        
        if (!(Test-Path $RemotePath)) {
            Write-Error "Impossible d'accéder au partage administratif $RemotePath. Vérifie les droits admin ou la lettre de lecteur sur $FileServer."
            return
        }

        # Résolution par SID universel pour éviter les erreurs de langue (FR/EN) sur "CREATOR OWNER"
        $SidCreatorOwner = New-Object System.Security.Principal.SecurityIdentifier("S-1-3-0")

        foreach ($Service in $Services) {
            $UNCPathForDDC = Join-Path $RemotePath $Service.FolderName
            $LocalGroup    = "OPT_GrL_$($Service.Name)"
            
            # Création propre du dossier si inexistant
            if (!(Test-Path $UNCPathForDDC)) {
                New-Item -ItemType Directory -Path $UNCPathForDDC -Force | Out-Null
                Write-Host "Dossier créé : $UNCPathForDDC" -ForegroundColor White
            }

            $Acl = Get-Acl $UNCPathForDDC
            $Acl.SetAccessRuleProtection($true, $false) # Blocage strict de l'héritage

            # Injection des ACEs de base immuables
            $ArSystem    = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArAdminsLoc = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrateurs", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArAdminsDom = New-Object System.Security.AccessControl.FileSystemAccessRule("$DomainName\Admins du domaine", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArCreator   = New-Object System.Security.AccessControl.FileSystemAccessRule($SidCreatorOwner, "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")

            $Acl.AddAccessRule($ArSystem)
            $Acl.AddAccessRule($ArAdminsLoc)
            $Acl.AddAccessRule($ArAdminsDom)
            $Acl.AddAccessRule($ArCreator)

            # Cas particulier : Partage Commun ou Partage unitaire de Service
            if ($Service.Name -eq "Commun") {
                foreach ($G in $Services) {
                    $TargetLocalSubGroup = "OPT_GrL_$($G.Name)"
                    $ArSubGroup = New-Object System.Security.AccessControl.FileSystemAccessRule("$DomainName\$TargetLocalSubGroup", "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")
                    $Acl.AddAccessRule($ArSubGroup)
                }
            } else {
                # ---------------------------------------------------------------------
                # SPLIT ACE POUR OBTENIR LES "DROITS SPECIAUX" (PROPRIETAIRE DYNAMIQUE)
                # ---------------------------------------------------------------------
                # ACE 1 : Application sur "Ce dossier et les sous-dossiers" uniquement
                $ArServiceFolder = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$DomainName\$LocalGroup", 
                    "Modify", 
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit, 
                    [System.Security.AccessControl.PropagationFlags]::None, 
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                
                # ACE 2 : Application sur "Les sous-dossiers et les fichiers seulement" (Héritage sous-jacent)
                $ArServiceSubItems = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$DomainName\$LocalGroup", 
                    "Modify", 
                    ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit), 
                    [System.Security.AccessControl.PropagationFlags]::InheritOnly, 
                    [System.Security.AccessControl.AccessControlType]::Allow
                )

                $Acl.AddAccessRule($ArServiceFolder)
                $Acl.AddAccessRule($ArServiceSubItems)
            }

            # Application définitive des descripteurs de sécurité
            Set-Acl $UNCPathForDDC $Acl
            Write-Host "NTFS sécurisé (Droits spéciaux assignés) -> $UNCPathForDDC" -ForegroundColor Cyan
        }

        # -----------------------------------------------------------------------------
        # ETAPE 3 : CONFIGURATION DISTANTE DES PARTAGES SMB (VIA CIM MODULE)
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 3 : CREATION DES PARTAGES A DISTANCE SUR OPT-FS02 ---" -ForegroundColor Green

        foreach ($Service in $Services) {
            # Construction du chemin local strict (Ex: P:\OPT_RH) pour le moteur SMB distant
            $LocalPathOnFS = "$LocalDrive`:\$($Service.FolderName)"
            $LocalGroup    = "OPT_GrL_$($Service.Name)"
            
            $ShareName = Split-Path $Service.FolderName -Leaf
            if ($Service.Name -eq "Dev") { $ShareName = "OPT_Dev" }

            if (!(Get-SmbShare -CimSession $FileServer -Name $ShareName -ErrorAction SilentlyContinue)) {
                
                # Création du partage
                New-SmbShare -CimSession $FileServer -Name $ShareName -Path $LocalPathOnFS -Description "Partage Service $($Service.Name)" | Out-Null
                
                # Purge de l'autorisation "Tout le monde" (Sécurité minimale)
                Revoke-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "Tout le monde" -Force | Out-Null
                
                # Attribution des droits d'accès au Partage SMB (FullControl pour l'administration et le groupe local)
                Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "BUILTIN\Administrateurs" -AccessRight Full -Force | Out-Null
                Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "$DomainName\Admins du domaine" -AccessRight Full -Force | Out-Null

                if ($Service.Name -eq "Commun") {
                    foreach ($G in $Services) {
                        $TargetLocalSubGroup = "OPT_GrL_$($G.Name)"
                        Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "$DomainName\$TargetLocalSubGroup" -AccessRight Full -Force | Out-Null
                    }
                } else {
                    Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "$DomainName\$LocalGroup" -AccessRight Full -Force | Out-Null
                }
                Write-Host "Partage SMB [$ShareName] configuré avec succès." -ForegroundColor Gray
            } else {
                Write-Host "Le partage SMB [$ShareName] existe déjà. Passage." -ForegroundColor DarkGray
            }
        }
        Write-Host "`n--- DEPLOIEMENT GLOBAL REUSSI ET CLOTURE ---" -ForegroundColor Green
    }
}

# Lancement global de la structure
Invoke-InfraDeployment