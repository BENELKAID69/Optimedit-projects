<#
.SYNOPSIS
    Deploy-OPTFileInfra.ps1 - Version 6.1 (Production / Fix Limite SamAccountName AD 20 caractères).
    Script d'automatisation et de déploiement global pour l'infrastructure d'identité (OUs, Groupes, 
    Utilisateurs), de stockage et de partage réseau de l'environnement optimedit.eu.

.DESCRIPTION
    Ce script centralisé est conçu pour être exécuté directement depuis un contrôleur de domaine 
    (ex: opt-dc02). Il orchestre de bout en bout l'approvisionnement des ressources logiques AD 
    et physiques du serveur de fichiers à distance (opt-fs02).

    Tâches exécutées de manière séquentielle :
    1. Validation d'environnement : Vérification de la présence du module ActiveDirectory et de la 
       connectivité réseau ICMP vers le serveur de fichiers cible.
    2. Modélisation Active Directory (OUs) : Création récursive de l'arborescence des Unités Organisationnelles 
       pour les Groupes (_Entreprises -> OPT -> Groupes) et pour les Utilisateurs (_Entreprises -> OPT -> Utilisateurs).
    3. Stratégie de sécurité AGDLP & Comptes : Génération automatique des trois couches de groupes de sécurité 
       (Domaine Local 'GrL', Global 'GrG', Universel 'GrU') pour chaque service métier. Création d'un utilisateur 
       dédié par service avec un mot de passe initial identique à son SamAccountName. Un mécanisme de sécurité 
       est intégré pour tronquer automatiquement le SamAccountName à 20 caractères maximum (limite stricte Windows) 
       pour éviter les erreurs sur les services longs comme "Comptabilite".
    4. Provisionnement du Stockage : Création à distance des répertoires physiques sur le volume ciblé (P:) 
       via les partages administratifs cachés (P$).
    5. Sécurisation NTFS Avancée (Droits Spéciaux) : Rupture stricte de l'héritage de sécurité sur chaque 
       racine de service. Application fine des accès pour les groupes de service via un découpage en deux ACEs 
       distinctes provoquant l'affichage des "Droits spéciaux" (AGDLP) dans l'interface Windows.
    6. Exposition SMB : Création distante des partages réseau via CIM/WMI et attribution des droits de partage 
       exclusifs aux groupes locaux (GrL).

.PARAMETER Aucun
    Ce script ne prend aucun argument en entrée pour sécuriser son exécution.

.NOTES
    AUTEUR       : Driss BENELKAID (Independent IT Consultant)
    ENTREPRISE   : optimedit.eu
    DATE         : 08/06/2026
    VERSION      : 6.1
    HISTORIQUE   :
      - v4.0        : Version initiale acceptée (OUs imbriquées et variables dynamiques).
      - v5.2        : Fractionnement des règles d'accès (Split ACE) pour forcer les "Droits Spéciaux" NTFS.
      - v6.0        : Ajout du provisionnement automatique des comptes utilisateurs par service.
      - v6.1 (Actuelle) : Résolution du bug de dépassement de capacité (20 caractères max) sur le SamAccountName 
                          pour l'utilisateur du service Comptabilité.
#>

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
        $UserDomain   = (Get-ADDomain).UserPrincipalNameSuffix

        # Validation de la connectivité réseau vers opt-fs02
        if (!(Test-Connection -ComputerName $FileServer -Count 1 -Quiet)) {
            Write-Error "Le serveur de fichiers cible [$FileServer] est injoignable. Arrêt du script."
            return
        }

        # -----------------------------------------------------------------------------
        # BLOC INITIALISATION : OU ARBORESCENCE (GROUPES ET UTILISATEURS)
        # -----------------------------------------------------------------------------
        Write-Host "--- VALIDATION DE L'ARBORESCENCE DES OUs ---" -ForegroundColor Green
        
        # 1. Racine commune et structure des Groupes
        $OUStructureGroupes = @("_Entreprises", "OPT", "Groupes")
        $CurrentParentDN = $DomainDN
        foreach ($OUName in $OUStructureGroupes) {
            $TargetOUCheck = "OU=$OUName,$CurrentParentDN"
            if (!(Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOUCheck'" -ErrorAction SilentlyContinue)) {
                Write-Host "Création de l'OU : $OUName" -ForegroundColor Cyan
                New-ADOrganizationalUnit -Name $OUName -Path $CurrentParentDN -ErrorAction Stop | Out-Null
            }
            $CurrentParentDN = $TargetOUCheck
        }
        $GroupOUDN = $CurrentParentDN

        # 2. Validation / Création spécifique pour l'OU Utilisateurs
        $UserOUDN = "OU=Utilisateurs,OU=OPT,OU=_Entreprises,$DomainDN"
        if (!(Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$UserOUDN'" -ErrorAction SilentlyContinue)) {
            Write-Host "Création de l'OU cible pour les Utilisateurs : Utilisateurs" -ForegroundColor Cyan
            $UserParentDN = "OU=OPT,OU=_Entreprises,$DomainDN"
            New-ADOrganizationalUnit -Name "Utilisateurs" -Path $UserParentDN -ErrorAction Stop | Out-Null
        }

        # -----------------------------------------------------------------------------
        # ETAPE 1 : STRATEGIE DE GROUPES AD (AGDLP) & PROVISIONNEMENT DES UTILISATEURS
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 1 : STRATEGIE DE GROUPES & COMPTES AD ---" -ForegroundColor Green
        foreach ($Service in $Services) {
            $LocalGroup     = "OPT_GrL_$($Service.Name)"
            $GlobalGroup    = "OPT_GrG_$($Service.Name)"
            $UniversalGroup = "OPT_GrU_$($Service.Name)"
            
            # Nom d'affichage de base
            $FullUserName   = "OPT_User_$($Service.Name)"
            
            # FIX SECURITE : Troncation stricte du SamAccountName à 20 caractères max (Contrainte héritée Active Directory)
            $SamAccountName = $FullUserName
            if ($SamAccountName.Length -gt 20) {
                $SamAccountName = $SamAccountName.Substring(0, 20)
            }

            # Création des groupes si inexistants
            if (!(Get-ADGroup -Filter "Name -eq '$GlobalGroup'")) {
                New-ADGroup -Name $GlobalGroup -GroupScope Global -GroupCategory Security -Path $GroupOUDN | Out-Null
            }
            if (!(Get-ADGroup -Filter "Name -eq '$UniversalGroup'")) {
                New-ADGroup -Name $UniversalGroup -GroupScope Universal -GroupCategory Security -Path $GroupOUDN | Out-Null
            }
            if (!(Get-ADGroup -Filter "Name -eq '$LocalGroup'")) {
                New-ADGroup -Name $LocalGroup -GroupScope DomainLocal -GroupCategory Security -Path $GroupOUDN | Out-Null
                Write-Host "Groupes de sécurité créés pour le service : $($Service.Name)" -ForegroundColor Cyan
            }
            
            # Implémentation de la cascade AGDLP (Inclusion dans le groupe local)
            Add-ADGroupMember -Identity $LocalGroup -Members $GlobalGroup, $UniversalGroup -ErrorAction SilentlyContinue

            # -------------------------------------------------------------------------
            # CREATION ET INTEGRATION DE L'UTILISATEUR ASSOCIE
            # -------------------------------------------------------------------------
            if (!(Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'")) {
                # Le mot de passe reste égal au SamAccountName validé et raccourci
                $SecurePassword = ConvertTo-SecureString $SamAccountName -AsPlainText -Force
                $UPN = "$SamAccountName@$UserDomain"

                # Création sécurisée du compte utilisateur
                New-ADUser -Name $FullUserName `
                           -SamAccountName $SamAccountName `
                           -UserPrincipalName $UPN `
                           -AccountPassword $SecurePassword `
                           -Path $UserOUDN `
                           -Enabled $true `
                           -ChangePasswordAtLogon $false | Out-Null

                Write-Host "Utilisateur créé avec succès : $SamAccountName (Actif)" -ForegroundColor Yellow
            }

            # Ajout de l'utilisateur dans son Groupe Global correspondant (G du AGDLP) via son SamAccountName
            Add-ADGroupMember -Identity $GlobalGroup -Members $SamAccountName -ErrorAction SilentlyContinue
        }

        # -----------------------------------------------------------------------------
        # ETAPE 2 : CREATION DES REPERTOIRES ET SECURISATION NTFS SPECIFIQUE
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 2 : CREATION DOSSIERS ET NTFS A DISTANCE ---" -ForegroundColor Green
        
        if (!(Test-Path $RemotePath)) {
            Write-Error "Impossible d'accéder au partage administratif $RemotePath. Vérifie les droits admin ou la lettre de lecteur sur $FileServer."
            return
        }

        $SidCreatorOwner = New-Object System.Security.Principal.SecurityIdentifier("S-1-3-0")

        foreach ($Service in $Services) {
            $UNCPathForDDC = Join-Path $RemotePath $Service.FolderName
            $LocalGroup    = "OPT_GrL_$($Service.Name)"
            
            if (!(Test-Path $UNCPathForDDC)) {
                New-Item -ItemType Directory -Path $UNCPathForDDC -Force | Out-Null
                Write-Host "Dossier créé : $UNCPathForDDC" -ForegroundColor White
            }

            $Acl = Get-Acl $UNCPathForDDC
            $Acl.SetAccessRuleProtection($true, $false)

            $ArSystem    = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArAdminsLoc = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrateurs", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArAdminsDom = New-Object System.Security.AccessControl.FileSystemAccessRule("$DomainName\Admins du domaine", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
            $ArCreator   = New-Object System.Security.AccessControl.FileSystemAccessRule($SidCreatorOwner, "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")

            $Acl.AddAccessRule($ArSystem)
            $Acl.AddAccessRule($ArAdminsLoc)
            $Acl.AddAccessRule($ArAdminsDom)
            $Acl.AddAccessRule($ArCreator)

            if ($Service.Name -eq "Commun") {
                foreach ($G in $Services) {
                    $TargetLocalSubGroup = "OPT_GrL_$($G.Name)"
                    $ArSubGroup = New-Object System.Security.AccessControl.FileSystemAccessRule("$DomainName\$TargetLocalSubGroup", "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")
                    $Acl.AddAccessRule($ArSubGroup)
                }
            } else {
                $ArServiceFolder = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    "$DomainName\$LocalGroup", 
                    "Modify", 
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit, 
                    [System.Security.AccessControl.PropagationFlags]::None, 
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                
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

            Set-Acl $UNCPathForDDC $Acl
            Write-Host "NTFS sécurisé (Droits spéciaux assignés) -> $UNCPathForDDC" -ForegroundColor Cyan
        }

        # -----------------------------------------------------------------------------
        # ETAPE 3 : CONFIGURATION DISTANTE DES PARTAGES SMB (VIA CIM MODULE)
        # -----------------------------------------------------------------------------
        Write-Host "`n--- ETAPE 3 : CREATION DES PARTAGES A DISTANCE SUR OPT-FS02 ---" -ForegroundColor Green

        foreach ($Service in $Services) {
            $LocalPathOnFS = "$LocalDrive`:\$($Service.FolderName)"
            $LocalGroup    = "OPT_GrL_$($Service.Name)"
            
            $ShareName = Split-Path $Service.FolderName -Leaf
            if ($Service.Name -eq "Dev") { $ShareName = "OPT_Dev" }

            if (!(Get-SmbShare -CimSession $FileServer -Name $ShareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -CimSession $FileServer -Name $ShareName -Path $LocalPathOnFS -Description "Partage Service $($Service.Name)" | Out-Null
                Revoke-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "Tout le monde" -Force | Out-Null
                Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "BUILTIN\Administrateurs" -AccessRight Full -Force | Out-Null
                Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "$DomainName\Admins du domaine" -AccessRight Full -Force | Out-Null

                if ($Service.Name -eq "Commun") {
                    foreach ($G in $Services) {
                        $TargetLocalSubGroup = "OPT_GrL_$($G.Name)"
                        Grant-SmbShareAccess -CimSession $FileServer -Name $ShareName -AccountName "$DomainName\$TargetLocalSubGroup" -AccessRight Full -Force | Null
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