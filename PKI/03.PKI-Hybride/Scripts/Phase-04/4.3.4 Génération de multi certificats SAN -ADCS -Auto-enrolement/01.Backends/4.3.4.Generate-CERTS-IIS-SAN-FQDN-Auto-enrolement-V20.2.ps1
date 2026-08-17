# ==================================================================================================
# Nom script : 4.3.4.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-V20.2.ps1
# Objet      : Enrôlement scripté d'un certificat SAN couvrant le FQDN local du serveur 
#              + les 13 domaines métier partagés.
# Déploiement: IDENTIQUE sur les 6 backends — auto-détection via $env:COMPUTERNAME.
# Auteur     : Optimedit
# Version    : 20.2
# Date       : 10/08/2026
#
# CORRECTIONS V20.2 :
#   - Liaison du certificat ADCS sur le port 443 (était manquante)
#   - Même certificat FQDN serveur sur tous les bindings HTTPS
# ==================================================================================================

Import-Module WebAdministration -ErrorAction Stop

# ==================================================================================================
# SECTION 1 : CONFIGURATION
# ==================================================================================================

${ScriptConfig} = @{
    TemplateName    = "IIS-FQDN-SAN-Auto-Enrollment"
    RenewBeforeDays = 30
    LogPath         = "C:\temp\cert-logs"
    LogFilePrefix   = "generate-cert-san"
    DomainSuffix    = (Get-CimInstance Win32_ComputerSystem).Domain
    ComputerName    = $env:COMPUTERNAME
    ScriptPath      = if ($MyInvocation.MyCommand.Path) { 
                          $MyInvocation.MyCommand.Path 
                      } else { 
                          "C:\Scripts\ADCS\4.3.4.Generate-CERTS-IIS-SAN-FQDN-Auto-enrolement-V20.2.ps1" 
                      }
}

${FqdnLocal} = "$(${ScriptConfig}.ComputerName).$(${ScriptConfig}.DomainSuffix)".ToLower()

${SiteMapping} = @{
    "Site_achat"        = @{ Domain = "achat.optimedit.eu"; DedicatedPort = 8068 }
    "Site_blog"         = @{ Domain = "blog.optimedit.eu"; DedicatedPort = 8072 }
    "Site_ce"           = @{ Domain = "ce.optimedit.eu"; DedicatedPort = 8064 }
    "Site_client"       = @{ Domain = "client.optimedit.eu"; DedicatedPort = 8070 }
    "Site_commercial"   = @{ Domain = "commercial.optimedit.eu"; DedicatedPort = 8069 }
    "Site_comptabilite" = @{ Domain = "comptabilite.optimedit.eu"; DedicatedPort = 8061 }
    "Site_direction"    = @{ Domain = "direction.optimedit.eu"; DedicatedPort = 8060 }
    "Site_formation"    = @{ Domain = "formation.optimedit.eu"; DedicatedPort = 8067 }
    "Site_it"           = @{ Domain = "it.optimedit.eu"; DedicatedPort = 8065 }
    "Site_juridique"    = @{ Domain = "juridique.optimedit.eu"; DedicatedPort = 8071 }
    "Site_paie"         = @{ Domain = "paie.optimedit.eu"; DedicatedPort = 8062 }
    "Site_production"   = @{ Domain = "production.optimedit.eu"; DedicatedPort = 8066 }
    "Site_rh"           = @{ Domain = "rh.optimedit.eu"; DedicatedPort = 8063 }
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
    }
    
    ${reportPath} = Join-Path ${ScriptConfig}.LogPath "synapse-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    ${report} | ConvertTo-Json -Depth 3 | Set-Content -Path ${reportPath} -Encoding UTF8
    Write-Log "📊 Rapport SYNAPSE généré : ${reportPath}" "SUCCESS" "Green"
    return ${reportPath}
}

# ==================================================================================================
# SECTION 3 : AUDIT
# ==================================================================================================

function Audit-IISSites {
    Write-Log "=== AUDIT IIS ===" "INFO" "Cyan"
    
    ${allSites} = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
    
    if (${allSites}.Count -eq 0) {
        Write-Log "⚠️ Aucun site trouvé" "WARNING" "Yellow"
        return $null
    }
    
    Write-Log "✅ $(${allSites}.Count) sites détectés" "SUCCESS" "Green"
    
    foreach (${site} in ${allSites}) {
        Write-Log "`n--- Site: $(${site}.Name) ---" "INFO" "Yellow"
        Write-Log "  État: $(${site}.State)" "INFO" "Gray"
        
        ${bindings} = Get-WebBinding -Name ${site}.Name
        
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
                
                Write-Log "    ${i}. ${protocol} ${ip}:${port} [${hostName}]${extra}" "INFO" "Gray"
            }
        }
    }
}

# ==================================================================================================
# SECTION 4 : NETTOYAGE
# ==================================================================================================

function Cleanup-AllBindings {
    param([string]${SiteName})
    
    ${logPrefix} = "[${SiteName}][CLEANUP]"
    
    try {
        ${bindings} = Get-WebBinding -Name ${SiteName}
        
        if (${bindings}.Count -eq 0) {
            Write-Log "${logPrefix} Aucun binding à supprimer" "INFO" "Gray"
            return $true
        }
        
        Write-Log "${logPrefix} Suppression de $(${bindings}.Count) bindings..." "INFO" "Yellow"
        
        foreach (${binding} in ${bindings}) {
            ${info} = ${binding}.bindingInformation
            ${protocol} = ${binding}.protocol
            ${parts} = ${info} -split ":"
            ${port} = ${parts}[1]
            ${hostName} = ${parts}[2]
            
            Remove-WebBinding -Name ${SiteName} -Protocol ${protocol} -Port ${port} -HostHeader ${hostName} -ErrorAction SilentlyContinue
            Write-Log "${logPrefix}   Suppression ${protocol}:${port} [${hostName}]" "DEBUG" "Gray"
        }
        
        ${remaining} = Get-WebBinding -Name ${SiteName}
        if (${remaining}.Count -eq 0) {
            Write-Log "${logPrefix} ✅ Tous les bindings supprimés" "SUCCESS" "Green"
            return $true
        } else {
            Write-Log "${logPrefix} ⚠️ $(${remaining}.Count) bindings restants" "WARNING" "Yellow"
            return $false
        }
        
    } catch {
        Write-Log "${logPrefix} ❌ Erreur: $($_.Exception.Message)" "ERROR" "Red"
        return $false
    }
}

# ==================================================================================================
# SECTION 5 : RECONSTRUCTION - CORRECTION : CERTIFICAT LIÉ SUR LES DEUX BINDINGS HTTPS
# ==================================================================================================

function Rebuild-SiteBindings {
    param(
        [string]${SiteName},
        [string]${Thumbprint},
        [string]${Domain},
        [int]${DedicatedPort}
    )
    
    ${logPrefix} = "[${SiteName}][REBUILD]"
    
    try {
        Write-Log "${logPrefix} Reconstruction des bindings..." "INFO" "Cyan"
        
        # ---- 1. HTTP:80 avec domaine complet (public) ----
        Write-Log "${logPrefix}   HTTP:80 → ${Domain} (public)" "INFO" "Gray"
        New-WebBinding -Name ${SiteName} -Protocol "http" -Port 80 -IPAddress "*" -HostHeader ${Domain} -ErrorAction Stop
        Write-Log "${logPrefix}   ✅ HTTP:80 créé" "SUCCESS" "Green"
        
        # ---- 2. HTTPS:443 avec domaine complet (public, SNI OUI) ----
        Write-Log "${logPrefix}   HTTPS:443 → ${Domain} (public, SNI OUI)" "INFO" "Gray"
        New-WebBinding -Name ${SiteName} -Protocol "https" -Port 443 -IPAddress "*" -HostHeader ${Domain} -SslFlags 1 -ErrorAction Stop
        Write-Log "${logPrefix}   ✅ HTTPS:443 créé (SNI OUI)" "SUCCESS" "Green"
        
        # ---- 3. LIER LE CERTIFICAT SUR LE PORT 443 ----
        ${binding443} = Get-WebBinding -Name ${SiteName} -Protocol "https" -Port 443 -HostHeader ${Domain}
        if (${binding443}) {
            ${binding443}.AddSslCertificate(${Thumbprint}, "my")
            Write-Log "${logPrefix}   ✅ Certificat ADCS lié sur HTTPS:443" "SUCCESS" "Green"
        } else {
            Write-Log "${logPrefix}   ❌ Binding HTTPS:443 non trouvé" "ERROR" "Red"
            return $false
        }
        
        # ---- 4. HTTPS:port dédié avec domaine complet (interne ARR, SNI NON) ----
        Write-Log "${logPrefix}   HTTPS:${DedicatedPort} → ${Domain} (interne ARR, SNI NON)" "INFO" "Gray"
        New-WebBinding -Name ${SiteName} -Protocol "https" -Port ${DedicatedPort} -IPAddress "*" -HostHeader ${Domain} -SslFlags 0 -ErrorAction Stop
        Write-Log "${logPrefix}   ✅ HTTPS:${DedicatedPort} créé (SNI NON)" "SUCCESS" "Green"
        
        # ---- 5. LIER LE CERTIFICAT SUR LE PORT DÉDIÉ ----
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
# SECTION 6 : DÉMARRAGE
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
# SECTION 7 : GESTION DU CERTIFICAT
# ==================================================================================================

function Ensure-Certificate {
    Write-Log "=== GESTION DU CERTIFICAT ADCS ===" "INFO" "Cyan"
    
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
    
    Write-Log "Demande d'un nouveau certificat ADCS..." "INFO" "Yellow"
    
    try {
        ${result} = Get-Certificate -Template ${ScriptConfig}.TemplateName `
                                -SubjectName "CN=${FqdnLocal}" `
                                -DnsName ${allSANs} `
                                -CertStoreLocation "Cert:\LocalMachine\My"
        
        if (${result}.Status -eq "Issued") {
            ${cert} = ${result}.Certificate
            ${cert}.FriendlyName = "IIS-SAN-Backend"
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
# SECTION 8 : MAIN
# ==================================================================================================

Write-Log "========================================" "INFO" "Cyan"
Write-Log "DÉMARRAGE DU SCRIPT D'ENRÔLEMENT CERTIFICAT V20.2" "INFO" "Cyan"
Write-Log "Serveur : ${FqdnLocal}" "INFO" "Cyan"
Write-Log "Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"

# --------------------------------------------------------------------------------
# AUDIT AVANT
# --------------------------------------------------------------------------------
Audit-IISSites

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
# GESTION DU CERTIFICAT
# --------------------------------------------------------------------------------
${cert} = Ensure-Certificate

if (-not ${cert}) {
    Write-Log "❌ Impossible de procéder sans un certificat valide. Arrêt." "ERROR" "Red"
    exit 1
}

${thumbprint} = ${cert}.Thumbprint

# --------------------------------------------------------------------------------
# NETTOYAGE ET RECONSTRUCTION
# --------------------------------------------------------------------------------
Write-Log "`n=== NETTOYAGE ET RECONSTRUCTION DES SITES ===" "INFO" "Cyan"

${successCount} = 0
${failCount} = 0
${siteResults} = @()

foreach (${siteName} in ${configuredSites}) {
    ${config} = ${SiteMapping}[${siteName}]
    
    Write-Log "`n--- Traitement: ${siteName} ---" "INFO" "Yellow"
    
    ${cleanupOk} = Cleanup-AllBindings -SiteName ${siteName}
    
    if (-not ${cleanupOk}) {
        Write-Log "❌ Échec du nettoyage pour ${siteName}" "ERROR" "Red"
        ${failCount}++
        ${siteResults} += "[KO] ${siteName}"
        continue
    }
    
    ${rebuildOk} = Rebuild-SiteBindings -SiteName ${siteName} `
                                        -Thumbprint ${thumbprint} `
                                        -Domain ${config}.Domain `
                                        -DedicatedPort ${config}.DedicatedPort
    
    if (${rebuildOk}) {
        Write-Log "✅ ${siteName} reconstruit avec succès" "SUCCESS" "Green"
        ${successCount}++
        ${siteResults} += "[OK] ${siteName}"
    } else {
        Write-Log "❌ Échec de la reconstruction pour ${siteName}" "ERROR" "Red"
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
Audit-IISSites

# --------------------------------------------------------------------------------
# RAPPORT FINAL
# --------------------------------------------------------------------------------
Write-Log "`n========================================" "INFO" "Cyan"
Write-Log "RÉSULTAT FINAL" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "✅ Sites reconstruits avec succès : ${successCount}" "SUCCESS" "Green"
Write-Log "❌ Sites en échec : ${failCount}" "ERROR" "Red"

Write-Log "`n=== État final des sites ===" "INFO" "Cyan"
${sites} = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
foreach (${site} in ${sites}) {
    ${icon} = if (${site}.State -eq "Started") { "🟢" } else { "🔴" }
    Write-Log "  ${icon} $(${site}.Name) : $(${site}.State)" "INFO" "Gray"
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
# SECTION 9 : TÂCHE PLANIFIÉE
# ==================================================================================================
<#
${taskName} = "IIS-SAN-Cert-Renewal"
${scriptPath} = ${ScriptConfig}.ScriptPath

${action} = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"${scriptPath}`""

${trigger} = New-ScheduledTaskTrigger -Daily -At 3am

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