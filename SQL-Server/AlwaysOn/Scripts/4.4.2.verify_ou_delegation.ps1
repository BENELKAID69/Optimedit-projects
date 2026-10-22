<#
.SYNOPSIS
    Vérifie les ACL déléguées au CNO CL-SQL-AG$ sur l'OU SQL Server.

.DESCRIPTION
    Ce script lit les Access Control Entries (ACE) sur l'OU cible
    et vérifie que CL-SQL-AG$ dispose bien des 4 permissions attendues :
      - Créer tous les objets enfants
      - Supprimer tous les objets enfants
      - Lire toutes les propriétés
      - Écrire toutes les propriétés

    Il compare les ACL réelles aux ACL attendues et affiche un verdict.

.PARAMETER OUPath
    Distinguished Name de l'OU à vérifier.
    Défaut : OU=SQL Server,OU=Serveurs,OU=OPT,OU=_Entreprises,DC=optimedit,DC=eu

.PARAMETER ClusterAccount
    Nom du compte ordinateur du cluster (sans le $).
    Défaut : CL-SQL-AG

.EXAMPLE
    .\4.4.2.verify_ou_delegation.ps1

.EXAMPLE
    .\4.4.2.verify_ou_delegation.ps1 -OUPath "OU=SQL Server,DC=optimedit,DC=eu"

.NOTES
    Auteur  : Projet AlwaysOn
    Version : 1.0
    Nœud    : DC03 (ou poste admin avec RSAT)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OUPath = "OU=SQL Server,OU=Serveurs,OU=OPT,OU=_Entreprises,DC=optimedit,DC=eu",

    [Parameter(Mandatory = $false)]
    [string]$ClusterAccount = "CL-SQL-AG"
)

# ============================================================
# FONCTIONS
# ============================================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 75) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "INFO"  { "Cyan" }
        default { "White" }
    }
    $prefix = switch ($Status) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERR]  " }
        "INFO"  { "[INFO] " }
        default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "4.4.2 - Script vérification ACL Délégation de contrôle sur l’OU SQL Server"
    Write-Host " OU cible         : $OUPath" -ForegroundColor Gray
    Write-Host " Compte cluster   : $ClusterAccount$" -ForegroundColor Gray
    Write-Host " DC               : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date             : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray

    # --- ÉTAPE 1 : Résoudre le SID du compte cluster ---
    Write-Section "Étape 1 : Résolution du SID du CNO"

    $computer = Get-ADComputer -Identity $ClusterAccount -ErrorAction Stop
    $clusterSID = $computer.SID
    Write-Step "Compte trouvé : $($computer.DistinguishedName)" "OK"
    Write-Step "SID : $clusterSID" "OK"

    # --- ÉTAPE 2 : Lire les ACL sur l'OU ---
    Write-Section "Étape 2 : Lecture des ACL sur l'OU"

    $acl = Get-Acl "AD:$OUPath"
    $clusterACEs = @($acl.Access | Where-Object {
        $_.IdentityReference.Value -eq $clusterSID -or
        $_.IdentityReference -like "*$ClusterAccount*"
    })

    Write-Step "Nombre d'ACE trouvées pour $ClusterAccount$ : $($clusterACEs.Count)" "INFO"

    if ($clusterACEs.Count -eq 0) {
        Write-Step "AUCUNE ACE trouvée pour $ClusterAccount$ sur cette OU !" "ERROR"
        Write-Host ""
        Write-Host "  ⚠️  La délégation n'est PAS configurée sur l'OU." -ForegroundColor Red
        Write-Host "  Le Listener Always On ne pourra PAS être créé automatiquement." -ForegroundColor Red
        exit 1
    }

    # --- ÉTAPE 3 : Afficher le détail des ACE ---
    Write-Section "Étape 3 : Détail des ACE pour $ClusterAccount$"

    $i = 1
    foreach ($ace in $clusterACEs) {
        Write-Host ""
        Write-Host "  ── ACE #$i ──" -ForegroundColor Magenta
        Write-Host "    IdentityReference    : $($ace.IdentityReference)" -ForegroundColor Gray
        Write-Host "    ActiveDirectoryRights: $($ace.ActiveDirectoryRights)" -ForegroundColor Gray
        Write-Host "    AccessControlType    : $($ace.AccessControlType)" -ForegroundColor Gray
        Write-Host "    InheritanceType      : $($ace.InheritanceType)" -ForegroundColor Gray
        if ($ace.ObjectType -ne [System.Guid]::Empty) {
            Write-Host "    ObjectType (GUID)    : $($ace.ObjectType)" -ForegroundColor Gray
            $objName = switch ($ace.ObjectType.ToString()) {
                "bf967a86-0de6-11d0-a285-00aa003049e2" { "Computer (classe)" }
                "00000000-0000-0000-0000-000000000000" { "Tous les objets" }
                default { "Autre" }
            }
            Write-Host "    ObjectType (nom)     : $objName" -ForegroundColor Gray
        } else {
            Write-Host "    ObjectType (GUID)    : (tous)" -ForegroundColor Gray
        }
        if ($ace.InheritedObjectType -ne [System.Guid]::Empty) {
            Write-Host "    InheritedObjectType  : $($ace.InheritedObjectType)" -ForegroundColor Gray
        }
        $i++
    }

    # --- ÉTAPE 4 : Vérification des 4 ACL attendues ---
    Write-Section "Étape 4 : Vérification des 4 ACL attendues"

    # Les 4 ACLs attendues par la délégation
    $expectedRights = @(
        @{ Name = "Créer tous les objets enfants";       Flag = "CreateChild" }
        @{ Name = "Supprimer tous les objets enfants";   Flag = "DeleteChild" }
        @{ Name = "Lire toutes les propriétés";          Flag = "ReadProperty" }
        @{ Name = "Écrire toutes les propriétés";        Flag = "WriteProperty" }
    )

    $computerGUID = "bf967a86-0de6-11d0-a285-00aa003049e2"
    $allPassed = $true

    foreach ($expected in $expectedRights) {
        $found = $false
        foreach ($ace in $clusterACEs) {
            if ($ace.ActiveDirectoryRights.ToString() -match $expected.Flag -and
                $ace.AccessControlType -eq "Allow") {
                $found = $true
                break
            }
        }

        if ($found) {
            Write-Step "$($expected.Name) : Présent" "OK"
        } else {
            Write-Step "$($expected.Name) : MANQUANT" "ERROR"
            $allPassed = $false
        }
    }

    # --- ÉTAPE 5 : Vérification spécifique pour la classe Computer ---
    Write-Section "Étape 5 : Vérification pour la classe Computer (GUID $computerGUID)"

    $computerSpecificACE = $clusterACEs | Where-Object {
        $_.ObjectType.ToString() -eq $computerGUID -and
        $_.ActiveDirectoryRights.ToString() -match "CreateChild" -and
        $_.AccessControlType -eq "Allow"
    }

    if ($computerSpecificACE) {
        Write-Step "Droit explicite sur la classe Computer : Présent" "OK"
        Write-Host "    InheritanceType : $($computerSpecificACE.InheritanceType)" -ForegroundColor Gray
    } else {
        Write-Step "Droit explicite sur la classe Computer : ABSENT" "WARN"
        Write-Host "    (Ce n'est pas bloquant si 'Créer tous les objets enfants' est présent)" -ForegroundColor DarkGray
    }

    # --- ÉTAPE 6 : Verdict final ---
    Write-Section "Verdict final"

    Write-Host ""
    if ($allPassed) {
        Write-Host "  ✅ La délégation AD est CORRECTEMENT configurée sur l'OU." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Le CNO $ClusterAccount$ peut :" -ForegroundColor Cyan
        Write-Host "    - Créer des objets ordinateur (dont le futur Listener SQL-AG-LSTNR$)" -ForegroundColor Gray
        Write-Host "    - Supprimer des objets ordinateur (nettoyage)" -ForegroundColor Gray
        Write-Host "    - Lire et écrire les propriétés des objets de l'OU" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Prochaine étape : activer Always On (5.1)" -ForegroundColor Yellow
    } else {
        Write-Host "  ⚠️  La délégation AD est INCOMPLÈTE sur l'OU." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Actions requises sur DC03 :" -ForegroundColor Yellow
        Write-Host "    1. Ouvrir 'Utilisateurs et ordinateurs Active Directory'" -ForegroundColor Gray
        Write-Host "    2. Activer 'Fonctionnalités avancées' (menu Affichage)" -ForegroundColor Gray
        Write-Host "    3. Naviguer jusqu'à : $OUPath" -ForegroundColor Gray
        Write-Host "    4. Clic droit → 'Déléguer le contrôle...'" -ForegroundColor Gray
        Write-Host "    5. Ajouter '$ClusterAccount$' et cocher les 4 ACL manquantes" -ForegroundColor Gray
    }

    # --- ÉTAPE 7 : Résumé ---
    Write-Host ""
    Write-Host ("─" * 75) -ForegroundColor DarkGray
    Write-Host "  RÉSUMÉ" -ForegroundColor Yellow
    Write-Host ("─" * 75) -ForegroundColor DarkGray
    Write-Host "  OU vérifiée          : $OUPath" -ForegroundColor Gray
    Write-Host "  Compte vérifié       : $ClusterAccount$" -ForegroundColor Gray
    Write-Host "  SID                  : $clusterSID" -ForegroundColor Gray
    Write-Host "  ACE trouvées         : $($clusterACEs.Count)" -ForegroundColor Gray
    Write-Host "  Verdict              : $(if ($allPassed) { 'CONFORME' } else { 'NON CONFORME' })" -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Red' })
    Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
}