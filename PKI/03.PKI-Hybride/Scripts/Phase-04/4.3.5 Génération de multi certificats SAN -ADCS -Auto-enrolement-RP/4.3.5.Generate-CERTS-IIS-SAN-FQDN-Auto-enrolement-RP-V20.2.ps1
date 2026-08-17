# ==================================================================================================
# Nom script : 4.3.5.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-RP-V20.2.ps1
# Objet      : Enrôlement scripté d'un certificat ADCS pour le Reverse-Proxy
#              Crée UNIQUEMENT les bindings HTTPS sur les ports dédiés (8060-8072)
#              NE TOUCHE PAS au port 443 (certificat public Let's Encrypt)
# Exécution  : Sur OPT-RP-01 (Reverse-Proxy) UNIQUEMENT
# Auteur     : Optimedit
# Version    : RP-V20.2
# Date       : 12/08/2026
#
# DESCRIPTION :
#   Ce script est un COMPLÉMENT au binding public existant sur le port 443.
#   Il crée les bindings HTTPS sur les ports dédiés (8060-8072) avec le certificat ADCS
#   pour permettre au TLS bridging de fonctionner.
#
#   Architecture TLS Bridging :
<#
┌───────────────────────────────────────────────────────────────────────────┐
│ Client                                                                    │
│     │                                                                     │
│     │ HTTPS:443 (certificat public Let's Encrypt) - Client Internet       │
│     │ HTTPS:8060-72 (certificat internt ADCS)     - Client interne        │
│     ▼                                                                     │
│ OPT-RP-01 (Reverse-Proxy)                                                 │
│     │                                                                     │
│     │ Script RP crée : HTTPS:8060-72 avec certificat ADCS                 │
│     │ Script RP ne touche PAS au port 443 (gardé par Certify Hub)         │
│     ▼                                                                     │
│ OPT-IIS-01..06 (Backends)                                                 │
│     │                                                                     │
│     │ Script Backend crée :                                               │
│     │   - HTTP:80 avec domaine complet                                    │
│     │   - HTTPS:443 avec certificat ADCS (SNI OUI)                        │
│     │   - HTTPS:8060-72 avec certificat ADCS (SNI NON)                    │
└───────────────────────────────────────────────────────────────────────────┘
#>

#   NE PAS EXÉCUTER CE SCRIPT SUR LES BACKENDS !!!
# ==================================================================================================

Import-Module WebAdministration -ErrorAction Stop

# ==================================================================================================
# SECTION 1 : CONFIGURATION
# ==================================================================================================

${ScriptConfig} = @{
    TemplateName    = "IIS-FQDN-SAN-Auto-Enrollment"
    RenewBeforeDays = 30
    LogPath         = "C:\temp\cert-logs"
    LogFilePrefix   = "generate-cert-san-rp"
    DomainSuffix    = (Get-CimInstance Win32_ComputerSystem).Domain
    ComputerName    = $env:COMPUTERNAME
    ScriptPath      = if ($MyInvocation.MyCommand.Path) { 
                          $MyInvocation.MyCommand.Path 
                      } else { 
                          "C:\Scripts\ADCS\4.3.5.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-RP-V20.2.ps1" 
                      }
}

#Test-Path "C:\Scripts\ADCS\4.3.5.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-RP-V20.2.ps1"

${FqdnLocal} = "$(${ScriptConfig}.ComputerName).$(${ScriptConfig}.DomainSuffix)".ToLower()

# Mapping des sites du RP (noms IIS sur le RP)
${SiteMapping} = @{
    "achat"         = @{ Domain = "achat.optimedit.eu"; DedicatedPort = 8068 }
    "blog"          = @{ Domain = "blog.optimedit.eu"; DedicatedPort = 8072 }
    "ce"            = @{ Domain = "ce.optimedit.eu"; DedicatedPort = 8064 }
    "client"        = @{ Domain = "client.optimedit.eu"; DedicatedPort = 8070 }
    "commercial"    = @{ Domain = "commercial.optimedit.eu"; DedicatedPort = 8069 }
    "comptabilite"  = @{ Domain = "comptabilite.optimedit.eu"; DedicatedPort = 8061 }
    "direction"     = @{ Domain = "direction.optimedit.eu"; DedicatedPort = 8060 }
    "formation"     = @{ Domain = "formation.optimedit.eu"; DedicatedPort = 8067 }
    "it"            = @{ Domain = "it.optimedit.eu"; DedicatedPort = 8065 }
    "juridique"     = @{ Domain = "juridique.optimedit.eu"; DedicatedPort = 8071 }
    "paie"          = @{ Domain = "paie.optimedit.eu"; DedicatedPort = 8062 }
    "production"    = @{ Domain = "production.optimedit.eu"; DedicatedPort = 8066 }
    "rh"            = @{ Domain = "rh.optimedit.eu"; DedicatedPort = 8063 }
}

# ==================================================================================================
# SECTION 2 : FONCTIONS
# ==================================================================================================

function Write-Log {
    param([string]${Message}, [string]${Level} = "INFO", [string]${Color} = "White")
    
    if (-not (Test-Path ${ScriptConfig}.LogPath)) {
        New-Item -ItemType Directory -Path ${ScriptConfig}.LogPath -Force | Out-Null
    }
    
    ${timestamp} = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ${logEntry} = "[${timestamp}] [${Level}] ${Message}"
    ${logFile} = Join-Path ${ScriptConfig}.LogPath "$(${ScriptConfig}.LogFilePrefix)-$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path ${logFile} -Value ${logEntry} -Encoding UTF8
    
    if (${Color} -ne "White") {
        Write-Host ${logEntry} -ForegroundColor ${Color}
    } else {
        Write-Host ${logEntry}
    }
}

function Get-CertTemplateName {
    param(${Cert})
    ${ext} = ${Cert}.Extensions | Where-Object {
        $_.Oid.Value -eq "1.3.6.1.4.1.311.20.2" -or 
        $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7"
    }
    if (${ext}) { return ${ext}.Format($false) }
    return $null
}

function Write-SynapseReport {
    param(
        [string]${Status},
        [string]${Server},
        [string]${CertificateThumbprint},
        [string]${CertificateExpiry},
        [int]${SitesProcessed},
        [int]${SitesFailed},
        [array]${SiteResults}
    )
    
    ${report} = @{
        ExecutionDate    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Server           = ${Server}
        Status           = ${Status}
        Certificate      = @{
            Thumbprint  = ${CertificateThumbprint}
            ExpiresOn   = ${CertificateExpiry}
        }
        SitesProcessed   = ${SitesProcessed}
        SitesFailed      = ${SitesFailed}
        SiteResults      = ${SiteResults}
        ScriptType       = "RP - Ports dédiés uniquement"
    }
    
    ${reportPath} = Join-Path ${ScriptConfig}.LogPath "synapse-report-rp-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    ${report} | ConvertTo-Json -Depth 3 | Set-Content -Path ${reportPath} -Encoding UTF8
    Write-Log "📊 Rapport SYNAPSE généré : ${reportPath}" "SUCCESS" "Green"
    return ${reportPath}
}

# ==================================================================================================
# SECTION 3 : AUDIT - Vérifie les bindings existants
# ==================================================================================================

function Audit-RPSites {
    Write-Log "=== AUDIT IIS (RP - Ports dédiés uniquement) ===" "INFO" "Cyan"
    Write-Log "⚠️  ATTENTION : Ce script ne touche PAS au port 443" "WARNING" "Yellow"
    Write-Log "   Les bindings HTTPS:443 restent gérés par Certify Management Hub" "INFO" "Gray"
    Write-Log "" "INFO" "White"
    
    ${allSites} = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
    
    if (${allSites}.Count -eq 0) {
        Write-Log "⚠️ Aucun site trouvé" "WARNING" "Yellow"
        return $null
    }
    
    Write-Log "✅ $(${allSites}.Count) sites détectés" "SUCCESS" "Green"
    
    foreach (${site} in ${allSites}) {
        ${siteName} = ${site}.Name
        Write-Log "`n--- Site: ${siteName} ---" "INFO" "Yellow"
        Write-Log "  État: $(${site}.State)" "INFO" "Gray"
        
        ${bindings} = Get-WebBinding -Name ${siteName}
        
        if (${bindings}.Count -eq 0) {
            Write-Log "  ⚠️ Aucun binding trouvé" "WARNING" "Yellow"
        } else {
            Write-Log "  Bindings ($(${bindings}.Count)):" "INFO" "Gray"
            ${i} = 0
            foreach (${binding} in ${bindings}) {
                ${i}++
                ${info} = ${binding}.bindingInformation
                ${protocol} = ${binding}.protocol
                
                ${parts} = ${info} -split ":"
                ${ip} = if (${parts}[0]) { ${parts}[0] } else { "*" }
                ${port} = ${parts}[1]
                ${hostName} = if (${parts}[2] -and ${parts}[2] -ne "") { ${parts}[2] } else { "(vide)" }
                
                ${extra} = ""
                if (${protocol} -eq "https") {
                    ${extra} = " (SNI: $(${binding}.SslFlags -eq 1))"
                    if (${binding}.CertificateHash) {
                        ${extra} += " Cert: $(${binding}.CertificateHash.Substring(0,8))..."
                    }
                }
                
                # Marquer les bindings dédiés
                ${isDedicated} = if (${port} -match "^(806[0-9]|807[0-2])$") { " 🔑 DÉDIÉ" } else { " 📌 PUBLIC 443" }
                
                Write-Log "    ${i}. ${protocol} ${ip}:${port} [${hostName}]${extra}${isDedicated}" "INFO" "Gray"
            }
        }
    }
}

# ==================================================================================================
# SECTION 4 : NETTOYAGE - Supprime UNIQUEMENT les bindings sur ports dédiés
# ==================================================================================================

function Cleanup-DedicatedBindings {
    param([string]${SiteName})
    
    ${logPrefix} = "[${SiteName}][CLEANUP-DEDICATED]"
    
    try {
        ${bindings} = Get-WebBinding -Name ${SiteName}
        ${deleted} = 0
        
        foreach (${binding} in ${bindings}) {
            ${info} = ${binding}.bindingInformation
            ${protocol} = ${binding}.protocol
            ${parts} = ${info} -split ":"
            ${port} = ${parts}[1]
            ${hostName} = ${parts}[2]
            
            # Supprimer UNIQUEMENT les bindings sur ports dédiés (8060-8072)
            if (${port} -match "^(806[0-9]|807[0-2])$") {
                Remove-WebBinding -Name ${SiteName} -Protocol ${protocol} -Port ${port} -HostHeader ${hostName} -ErrorAction SilentlyContinue
                Write-Log "${logPrefix}   Suppression ${protocol}:${port} [${hostName}]" "DEBUG" "Gray"
                ${deleted}++
            }
            # NE PAS SUPPRIMER LE PORT 443
        }
        
        if (${deleted} -gt 0) {
            Write-Log "${logPrefix} ✅ ${deleted} binding(s) dédié(s) supprimés (port 443 conservé)" "SUCCESS" "Green"
        } else {
            Write-Log "${logPrefix} Aucun binding dédié à supprimer" "INFO" "Gray"
        }
        
        return $true
        
    } catch {
        Write-Log "${logPrefix} ❌ Erreur: $($_.Exception.Message)" "ERROR" "Red"
        return $false
    }
}

# ==================================================================================================
# SECTION 5 : RECONSTRUCTION - Crée UNIQUEMENT les bindings sur ports dédiés
# ==================================================================================================

function Rebuild-DedicatedBindings {
    param(
        [string]${SiteName},
        [string]${Thumbprint},
        [string]${Domain},
        [int]${DedicatedPort}
    )
    
    ${logPrefix} = "[${SiteName}][REBUILD-DEDICATED]"
    
    try {
        Write-Log "${logPrefix} Création du binding dédié..." "INFO" "Cyan"
        Write-Log "${logPrefix}   HTTPS:${DedicatedPort} → ${Domain} (interne ARR, SNI NON)" "INFO" "Gray"
        
        # Créer le binding HTTPS sur le port dédié avec SNI désactivé (SslFlags=0)
        New-WebBinding -Name ${SiteName} -Protocol "https" -Port ${DedicatedPort} -IPAddress "*" -HostHeader ${Domain} -SslFlags 0 -ErrorAction Stop
        Write-Log "${logPrefix}   ✅ HTTPS:${DedicatedPort} créé (SNI NON)" "SUCCESS" "Green"
        
        # Lier le certificat ADCS sur le port dédié
        ${bindingDedicated} = Get-WebBinding -Name ${SiteName} -Protocol "https" -Port ${DedicatedPort} -HostHeader ${Domain}
        if (${bindingDedicated}) {
            ${bindingDedicated}.AddSslCertificate(${Thumbprint}, "my")
            Write-Log "${logPrefix}   ✅ Certificat ADCS lié sur HTTPS:${DedicatedPort}" "SUCCESS" "Green"
        } else {
            Write-Log "${logPrefix}   ❌ Binding HTTPS:${DedicatedPort} non trouvé" "ERROR" "Red"
            return $false
        }
        
        return $true
        
    } catch {
        Write-Log "${logPrefix}   ❌ Erreur: $($_.Exception.Message)" "ERROR" "Red"
        return $false
    }
}

# ==================================================================================================
# SECTION 6 : DÉMARRAGE DES SITES
# ==================================================================================================

function Start-IISSites {
    Write-Log "=== DÉMARRAGE DES SITES ===" "INFO" "Yellow"
    
    ${startedCount} = 0
    ${failedCount} = 0
    ${sites} = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
    ${siteResults} = @()
    
    foreach (${site} in ${sites}) {
        ${siteName} = ${site}.Name
        Write-Log "  Démarrage de ${siteName}..." "INFO" "Gray"
        
        try {
            Start-Website -Name ${siteName} -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            
            ${siteAfter} = Get-Website -Name ${siteName}
            
            if (${siteAfter}.State -eq "Started") {
                Write-Log "  ✅ ${siteName} : Started" "SUCCESS" "Green"
                ${startedCount}++
                ${siteResults} += "[OK] ${siteName}"
            } else {
                Write-Log "  ⚠️ ${siteName} : $(${siteAfter}.State)" "WARNING" "Yellow"
                ${failedCount}++
                ${siteResults} += "[KO] ${siteName}"
            }
        } catch {
            Write-Log "  ❌ ${siteName} : erreur $($_.Exception.Message)" "ERROR" "Red"
            ${failedCount}++
            ${siteResults} += "[KO] ${siteName}"
        }
    }
    
    Write-Log "Résultat: ${startedCount} démarrés, ${failedCount} en échec" "INFO" "Cyan"
    return @{
        StartedCount = ${startedCount}
        FailedCount  = ${failedCount}
        Results      = ${siteResults}
    }
}

# ==================================================================================================
# SECTION 7 : GESTION DU CERTIFICAT ADCS
# ==================================================================================================

function Ensure-Certificate {
    Write-Log "=== GESTION DU CERTIFICAT ADCS (RP) ===" "INFO" "Cyan"
    Write-Log "  Ce certificat sera utilisé pour les ports dédiés UNIQUEMENT" "INFO" "Gray"
    Write-Log "  Le port 443 continue d'utiliser le certificat public Let's Encrypt" "INFO" "Gray"
    Write-Log "" "INFO" "White"
    
    ${metierDomains} = ${SiteMapping}.Values.Domain | Sort-Object
    ${allSANs} = @(${FqdnLocal}) + ${metierDomains}
    
    Write-Log "$(${allSANs}.Count) noms dans le SAN:" "INFO" "Gray"
    foreach (${san} in ${allSANs}) {
        Write-Log "  - ${san}" "INFO" "Gray"
    }
    
    ${existingCert} = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Subject -eq "CN=${FqdnLocal}" -and
        (Get-CertTemplateName $_) -like "*$(${ScriptConfig}.TemplateName)*" -and
        $_.NotAfter -gt (Get-Date).AddDays(${ScriptConfig}.RenewBeforeDays)
    }
    
    if (${existingCert}) {
        ${cert} = ${existingCert}[0]
        Write-Log "✅ Certificat ADCS existant valide" "SUCCESS" "Green"
        Write-Log "  Thumbprint: $(${cert}.Thumbprint)" "INFO" "Gray"
        Write-Log "  Expire le: $(${cert}.NotAfter)" "INFO" "Gray"
        return ${cert}
    }
    
    Write-Log "Demande d'un nouveau certificat ADCS pour le RP..." "INFO" "Yellow"
    
    try {
        ${result} = Get-Certificate -Template ${ScriptConfig}.TemplateName `
                                -SubjectName "CN=${FqdnLocal}" `
                                -DnsName ${allSANs} `
                                -CertStoreLocation "Cert:\LocalMachine\My"
        
        if (${result}.Status -eq "Issued") {
            ${cert} = ${result}.Certificate
            ${cert}.FriendlyName = "IIS-SAN-Backend-RP"
            Write-Log "✅ Certificat ADCS émis" "SUCCESS" "Green"
            Write-Log "  Thumbprint: $(${cert}.Thumbprint)" "INFO" "Gray"
            Write-Log "  Expire le: $(${cert}.NotAfter)" "INFO" "Gray"
            return ${cert}
        } elseif (${result}.Status -eq "Pending") {
            Write-Log "⏳ Demande en attente d'approbation CA" "WARNING" "Yellow"
            return $null
        } else {
            Write-Log "❌ Échec: $(${result}.Status)" "ERROR" "Red"
            return $null
        }
    } catch {
        Write-Log "❌ Erreur: $($_.Exception.Message)" "ERROR" "Red"
        return $null
    }
}

# ==================================================================================================
# SECTION 8 : MAIN - EXÉCUTION PRINCIPALE
# ==================================================================================================

Write-Log "========================================" "INFO" "Cyan"
Write-Log "SCRIPT RP - BINDINGS PORTS DÉDIÉS UNIQUEMENT" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "Serveur : ${FqdnLocal}" "INFO" "Cyan"
Write-Log "Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Cyan"
Write-Log "" "INFO" "White"
Write-Log "⚠️  ATTENTION : Ce script est pour le REVERSE-PROXY UNIQUEMENT" "WARNING" "Yellow"
Write-Log "   Il ne touche PAS au port 443 (certificat public Let's Encrypt)" "INFO" "Gray"
Write-Log "   Il crée UNIQUEMENT les bindings HTTPS sur les ports 8060-8072" "INFO" "Gray"
Write-Log "========================================" "INFO" "Cyan"

# --------------------------------------------------------------------------------
# AUDIT AVANT
# --------------------------------------------------------------------------------
Audit-RPSites

# --------------------------------------------------------------------------------
# VÉRIFICATION DES SITES
# --------------------------------------------------------------------------------
Write-Log "`n=== VÉRIFICATION DES SITES CONFIGURÉS ===" "INFO" "Cyan"

${configuredSites} = @()
foreach (${siteName} in ${SiteMapping}.Keys) {
    ${site} = Get-Website -Name ${siteName} -ErrorAction SilentlyContinue
    if (${site}) {
        ${configuredSites} += ${siteName}
        Write-Log "  ✅ ${siteName} trouvé" "SUCCESS" "Green"
    } else {
        Write-Log "  ⚠️ ${siteName} non trouvé" "WARNING" "Yellow"
    }
}

if (${configuredSites}.Count -eq 0) {
    Write-Log "❌ Aucun site configuré trouvé. Arrêt." "ERROR" "Red"
    exit 1
}

Write-Log "✅ $(${configuredSites}.Count) sites à traiter" "SUCCESS" "Green"

# --------------------------------------------------------------------------------
# GESTION DU CERTIFICAT ADCS
# --------------------------------------------------------------------------------
${cert} = Ensure-Certificate

if (-not ${cert}) {
    Write-Log "❌ Impossible de procéder sans un certificat ADCS valide. Arrêt." "ERROR" "Red"
    exit 1
}

${thumbprint} = ${cert}.Thumbprint

# --------------------------------------------------------------------------------
# NETTOYAGE DES BINDINGS DÉDIÉS
# --------------------------------------------------------------------------------
Write-Log "`n=== NETTOYAGE DES BINDINGS DÉDIÉS ===" "INFO" "Cyan"

foreach (${siteName} in ${configuredSites}) {
    Cleanup-DedicatedBindings -SiteName ${siteName}
}

# --------------------------------------------------------------------------------
# RECONSTRUCTION DES BINDINGS DÉDIÉS
# --------------------------------------------------------------------------------
Write-Log "`n=== CRÉATION DES BINDINGS DÉDIÉS (8060-8072) ===" "INFO" "Cyan"

${successCount} = 0
${failCount} = 0
${siteResults} = @()

foreach (${siteName} in ${configuredSites}) {
    ${config} = ${SiteMapping}[${siteName}]
    
    Write-Log "`n--- Traitement: ${siteName} ---" "INFO" "Yellow"
    Write-Log "  Port dédié : ${config}.DedicatedPort" "INFO" "Gray"
    Write-Log "  Domaine : ${config}.Domain" "INFO" "Gray"
    
    ${rebuildOk} = Rebuild-DedicatedBindings -SiteName ${siteName} `
                                             -Thumbprint ${thumbprint} `
                                             -Domain ${config}.Domain `
                                             -DedicatedPort ${config}.DedicatedPort
    
    if (${rebuildOk}) {
        Write-Log "✅ ${siteName} : binding dédié créé avec succès" "SUCCESS" "Green"
        ${successCount}++
        ${siteResults} += "[OK] ${siteName}"
    } else {
        Write-Log "❌ Échec de la création du binding dédié pour ${siteName}" "ERROR" "Red"
        ${failCount}++
        ${siteResults} += "[KO] ${siteName}"
    }
}

# --------------------------------------------------------------------------------
# DÉMARRAGE DES SITES
# --------------------------------------------------------------------------------
Write-Log "`n=== DÉMARRAGE DES SITES ===" "INFO" "Yellow"
${startResult} = Start-IISSites

# --------------------------------------------------------------------------------
# AUDIT APRÈS
# --------------------------------------------------------------------------------
Write-Log "`n=== AUDIT POST-EXÉCUTION ===" "INFO" "Cyan"
Audit-RPSites

# --------------------------------------------------------------------------------
# RAPPORT FINAL
# --------------------------------------------------------------------------------
Write-Log "`n========================================" "INFO" "Cyan"
Write-Log "RÉSULTAT FINAL" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "✅ Bindings dédiés créés avec succès : ${successCount}" "SUCCESS" "Green"
Write-Log "❌ Bindings dédiés en échec : ${failCount}" "ERROR" "Red"

Write-Log "`n=== État final des sites ===" "INFO" "Cyan"
${sites} = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
foreach (${site} in ${sites}) {
    ${icon} = if (${site}.State -eq "Started") { "🟢" } else { "🔴" }
    Write-Log "  ${icon} $(${site}.Name) : $(${site}.State)" "INFO" "Gray"
}

# --------------------------------------------------------------------------------
# VÉRIFICATION : Chaque site doit avoir 2 bindings HTTPS (443 + dédié)
# --------------------------------------------------------------------------------
Write-Log "`n=== VÉRIFICATION DES BINDINGS HTTPS ===" "INFO" "Cyan"
foreach (${siteName} in ${configuredSites}) {
    ${bindings} = Get-WebBinding -Name ${siteName} -Protocol "https"
    ${ports} = ${bindings} | ForEach-Object { ($_.bindingInformation -split ":")[1] }
    ${has443} = ${ports} -contains "443"
    ${hasDedicated} = ${ports} | Where-Object { $_ -match "^(806[0-9]|807[0-2])$" } | Measure-Object | Select-Object -ExpandProperty Count
    
    if (${has443} -and ${hasDedicated} -gt 0) {
        Write-Log "  ✅ ${siteName} : 443 + ${hasDedicated} port(s) dédié(s)" "SUCCESS" "Green"
    } else {
        Write-Log "  ⚠️ ${siteName} : 443: ${has443}, dédiés: ${hasDedicated}" "WARNING" "Yellow"
    }
}

# --------------------------------------------------------------------------------
# SYNAPSE
# --------------------------------------------------------------------------------
Write-Log "`n=== GÉNÉRATION DU RAPPORT SYNAPSE ===" "INFO" "Cyan"

${overallStatus} = if (${failCount} -eq 0 -and ${startResult}.FailedCount -eq 0) { "SUCCESS" } else { "PARTIAL" }

Write-SynapseReport -Status ${overallStatus} `
                    -Server ${FqdnLocal} `
                    -CertificateThumbprint ${thumbprint} `
                    -CertificateExpiry $(${cert}.NotAfter.ToString("yyyy-MM-dd")) `
                    -SitesProcessed ${successCount} `
                    -SitesFailed ${failCount} `
                    -SiteResults ${siteResults}

Write-Log "`n✅ Script terminé" "SUCCESS" "Green"
Write-Log "========================================" "INFO" "Cyan"

# ==================================================================================================
# SECTION 9 : TÂCHE PLANIFIÉE (Optionnelle - Décommenter pour activer)
# ==================================================================================================
<#
# Tâche planifiée pour le renouvellement des bindings dédiés sur le RP
${taskName} = "IIS-SAN-Cert-Renewal"
${scriptPath} = ${ScriptConfig}.ScriptPath

${action} = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"${scriptPath}`""

${trigger} = New-ScheduledTaskTrigger -Daily -At 10pm

${principal} = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

${settings} = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName ${taskName} `
    -Action ${action} `
    -Trigger ${trigger} `
    -Principal ${principal} `
    -Settings ${settings} `
    -Force

Write-Log "✅ Tâche planifiée '${taskName}' créée" "SUCCESS" "Green"
#>

