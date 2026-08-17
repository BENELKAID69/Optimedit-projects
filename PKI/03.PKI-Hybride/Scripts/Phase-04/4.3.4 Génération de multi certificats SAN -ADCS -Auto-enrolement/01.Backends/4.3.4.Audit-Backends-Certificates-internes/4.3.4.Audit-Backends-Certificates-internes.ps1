# ==================================================================================================
# Nom script : Audit-Backends-Certificates-V4.ps1
# Objet      : Audite les certificats sur les 6 backends IIS avec détails complets
# Exécution  : Sur OPT-RP-01 (Reverse-Proxy)
# Auteur     : Optimedit
# Date       : 10/08/2026
#
# CORRECTIONS V4 :
#   - Correction du champ Backend qui était vide dans le CSV
#   - Utilisation de $fqdn passé en argument au script block
#   - Amélioration de la structure des données retournées
# ==================================================================================================

# ==================================================================================================
# SECTION 1 : CONFIGURATION
# ==================================================================================================

$Backends = @(
    "OPT-IIS-01",
    "OPT-IIS-02",
    "OPT-IIS-03",
    "OPT-IIS-04",
    "OPT-IIS-05",
    "OPT-IIS-06"
)

$Domain = "optimedit.eu"

$LogPath = "C:\Scripts\ADCS\logs"
$OutputFile = "$LogPath\Audit-Certificates-V4-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$LogFile = "$LogPath\Audit-Certificates-V4-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ==================================================================================================
# SECTION 2 : FONCTIONS
# ==================================================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )
    
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    
    if ($Color -ne "White") {
        Write-Host $logEntry -ForegroundColor $Color
    } else {
        Write-Host $logEntry
    }
}

function Write-Header {
    Write-Log "" "INFO" "White"
    Write-Log "╔═══════════════════════════════════════════════════════════════╗" "INFO" "Cyan"
    Write-Log "║           AUDIT CERTIFICATS V4 - BACKENDS IIS               ║" "INFO" "Cyan"
    Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Cyan"
    Write-Log "  Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Gray"
    Write-Log "  Backends : $($Backends.Count)" "INFO" "Gray"
    Write-Log "  Output : $OutputFile" "INFO" "Gray"
    Write-Log "  Log : $LogFile" "INFO" "Gray"
    Write-Log "" "INFO" "White"
}

function Test-WinRMConnection {
    param([string]$ComputerName)
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        Remove-PSSession $session
        return $true
    } catch {
        return $false
    }
}

function Invoke-RemoteScriptBlock {
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [array]$ArgumentList = @()
    )
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $result = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        Remove-PSSession $session
        return $result
    } catch {
        Write-Log "  ❌ Erreur sur $ComputerName : $($_.Exception.Message)" "ERROR" "Red"
        return $null
    }
}

# ==================================================================================================
# SECTION 3 : AUDIT DES BACKENDS
# ==================================================================================================

Write-Header

Write-Log "=== DÉMARRAGE DE L'AUDIT V4 ===" "INFO" "Cyan"

$AllResults = @()
$SuccessCount = 0
$FailCount = 0
$MissingCertCount = 0
$CertHashCount = @{}

foreach ($backend in $Backends) {
    $fqdn = "$backend.$Domain"
    Write-Log "`n╔═══════════════════════════════════════════════════════════════╗" "INFO" "Yellow"
    Write-Log "║  Audit de $fqdn" "INFO" "Yellow"
    Write-Log "╚═══════════════════════════════════════════════════════════════╝" "INFO" "Yellow"
    
    # Test WinRM
    Write-Log "  [1/3] Test de la connexion WinRM..." "INFO" "Gray"
    if (-not (Test-WinRMConnection -ComputerName $fqdn)) {
        Write-Log "  ❌ Connexion WinRM impossible sur $fqdn" "ERROR" "Red"
        $FailCount++
        continue
    }
    Write-Log "  ✅ Connexion WinRM OK" "SUCCESS" "Green"
    
    # Script block d'audit avec le fqdn passé en argument
    $auditScriptBlock = {
        param(
            [string]$BackendFqdn
        )
        
        $results = @()
        
        # Récupérer TOUS les certificats du magasin LocalMachine\My
        $certificates = Get-ChildItem -Path "Cert:\LocalMachine\My" | ForEach-Object {
            @{
                Thumbprint = $_.Thumbprint
                Subject = $_.Subject
                Issuer = $_.Issuer
                NotAfter = $_.NotAfter
                SerialNumber = $_.SerialNumber
                FriendlyName = $_.FriendlyName
            }
        }
        
        # Créer un dictionnaire pour accès rapide
        $certHash = @{}
        foreach ($cert in $certificates) {
            $certHash[$cert.Thumbprint] = $cert
        }
        
        # Récupérer tous les sites
        $allSites = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
        
        foreach ($site in $allSites) {
            $siteName = $site.Name
            
            # Récupérer les bindings HTTPS
            $httpsBindings = Get-WebBinding -Name $siteName -Protocol "https" 2>$null
            
            if (-not $httpsBindings) {
                continue
            }
            
            foreach ($binding in $httpsBindings) {
                $info = $binding.bindingInformation
                $hash = $binding.certificateHash
                
                # Extraire le port et le hostHeader
                $parts = $info -split ":"
                $port = $parts[1]
                $hostHeader = if ($parts[2]) { $parts[2] } else { "(vide)" }
                
                # Récupérer les détails du certificat depuis le dictionnaire
                $certInfo = $certHash[$hash]
                
                if ($certInfo) {
                    $certSubject = $certInfo.Subject
                    $certIssuer = $certInfo.Issuer
                    $certExpiry = $certInfo.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")
                    $certFriendlyName = $certInfo.FriendlyName
                    $certStatus = "OK"
                } else {
                    $certSubject = "CERTIFICAT MANQUANT !"
                    $certIssuer = "N/A"
                    $certExpiry = "N/A"
                    $certFriendlyName = "N/A"
                    $certStatus = "MANQUANT"
                }
                
                # Créer l'objet avec le BackendFqdn passé en argument
                $results += [PSCustomObject]@{
                    SiteName = $siteName
                    Port = $port
                    HostHeader = $hostHeader
                    BindingInformation = $info
                    CertificateHash = $hash
                    CertificateSubject = $certSubject
                    CertificateIssuer = $certIssuer
                    CertificateExpiry = $certExpiry
                    CertificateFriendlyName = $certFriendlyName
                    CertificateStatus = $certStatus
                    Backend = $BackendFqdn
                }
            }
        }
        
        return @{
            Bindings = $results
            Certificates = $certificates
        }
    }
    
    Write-Log "  [2/3] Récupération des bindings HTTPS et certificats..." "INFO" "Gray"
    $remoteResult = Invoke-RemoteScriptBlock -ComputerName $fqdn -ScriptBlock $auditScriptBlock -ArgumentList $fqdn
    
    if ($remoteResult -eq $null) {
        Write-Log "  ❌ Échec de l'audit sur $fqdn" "ERROR" "Red"
        $FailCount++
        continue
    }
    
    $bindings = $remoteResult.Bindings
    $certificates = $remoteResult.Certificates
    
    Write-Log "  ✅ $($bindings.Count) bindings HTTPS trouvés" "SUCCESS" "Green"
    Write-Log "  ✅ $($certificates.Count) certificats dans le magasin" "SUCCESS" "Green"
    
    # Compter les certificats manquants
    $missing = $bindings | Where-Object { $_.CertificateStatus -eq "MANQUANT" } | Measure-Object | Select-Object -ExpandProperty Count
    if ($missing -gt 0) {
        Write-Log "  ⚠️ $missing bindings avec certificat manquant !" "WARNING" "Yellow"
        $MissingCertCount += $missing
    }
    
    # Ajouter les résultats à la collection globale
    $AllResults += $bindings
    
    # Compter les hash pour détection des doublons
    foreach ($item in $bindings) {
        if ($item.CertificateStatus -eq "OK") {
            if (-not $CertHashCount.ContainsKey($item.CertificateHash)) {
                $CertHashCount[$item.CertificateHash] = @{
                    Count = 0
                    Backends = @()
                    Subject = $item.CertificateSubject
                    Expiry = $item.CertificateExpiry
                }
            }
            $CertHashCount[$item.CertificateHash].Count++
            if ($CertHashCount[$item.CertificateHash].Backends -notcontains $fqdn) {
                $CertHashCount[$item.CertificateHash].Backends += $fqdn
            }
        }
    }
    
    $SuccessCount++
}

# ==================================================================================================
# SECTION 4 : EXPORT CSV
# ==================================================================================================

Write-Log "`n=== EXPORT DES RÉSULTATS ===" "INFO" "Cyan"

if ($AllResults.Count -gt 0) {
    $AllResults | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Log "  ✅ CSV exporté : $OutputFile" "SUCCESS" "Green"
    Write-Log "     $($AllResults.Count) lignes" "INFO" "Gray"
}

# ==================================================================================================
# SECTION 5 : RAPPORT DÉTAILLÉ
# ==================================================================================================

Write-Log "`n=== RAPPORT DÉTAILLÉ ===" "INFO" "Cyan"

# 5.1 : Synthèse par backend
Write-Log "`n--- SYNTHÈSE PAR BACKEND ---" "INFO" "Yellow"
$backendSummary = $AllResults | Group-Object Backend
foreach ($group in $backendSummary) {
    $backendName = $group.Name
    $total = $group.Count
    $missing = $group.Group | Where-Object { $_.CertificateStatus -eq "MANQUANT" } | Measure-Object | Select-Object -ExpandProperty Count
    $ok = $total - $missing
    
    $statusIcon = if ($missing -eq 0) { "✅" } else { "⚠️" }
    $statusColor = if ($missing -eq 0) { "Green" } else { "Yellow" }
    Write-Log "  $statusIcon $backendName : $ok OK / $missing manquants (Total: $total)" "INFO" $statusColor
}

# 5.2 : Certificats manquants
$missingBindings = $AllResults | Where-Object { $_.CertificateStatus -eq "MANQUANT" }
if ($missingBindings.Count -gt 0) {
    Write-Log "`n--- CERTIFICATS MANQUANTS ---" "INFO" "Red"
    $missingBindings | Group-Object Backend | ForEach-Object {
        $backendName = $_.Name
        $count = $_.Count
        Write-Log "  ❌ $backendName : $count bindings avec certificat manquant" "ERROR" "Red"
        $_.Group | ForEach-Object {
            Write-Log "      - $($_.SiteName) port $($_.Port) hash: $($_.CertificateHash.Substring(0,16))..." "ERROR" "Red"
        }
    }
} else {
    Write-Log "  ✅ Aucun certificat manquant" "SUCCESS" "Green"
}

# 5.3 : Vérification des bindings
Write-Log "`n--- VÉRIFICATION DES BINDINGS ---" "INFO" "Yellow"

# Vérifier que chaque site a bien les 2 bindings HTTPS (443 + dédié)
$siteCheck = $AllResults | Group-Object Backend, SiteName | ForEach-Object {
    $parts = $_.Name -split ", "
    $backend = $parts[0]
    $site = $parts[1]
    $ports = $_.Group | Select-Object -ExpandProperty Port
    $has443 = $ports -contains "443"
    $hasDedicated = $ports | Where-Object { $_ -ne "443" } | Measure-Object | Select-Object -ExpandProperty Count
    
    [PSCustomObject]@{
        Backend = $backend
        Site = $site
        Has443 = $has443
        DedicatedCount = $hasDedicated
        TotalBindings = $_.Count
        Status = if ($has443 -and $hasDedicated -gt 0) { "OK" } else { "INCOMPLET" }
    }
}

$invalidSites = $siteCheck | Where-Object { $_.Status -ne "OK" }
if ($invalidSites.Count -gt 0) {
    Write-Log "  ⚠️ Sites avec configuration incomplète :" "WARNING" "Yellow"
    foreach ($item in $invalidSites) {
        Write-Log "      $($item.Backend) / $($item.Site) : $($item.TotalBindings) bindings (443: $($item.Has443), dédiés: $($item.DedicatedCount))" "WARNING" "Yellow"
    }
} else {
    Write-Log "  ✅ Tous les sites ont les 2 bindings HTTPS (443 + port dédié)" "SUCCESS" "Green"
}

# 5.4 : Récapitulatif des certificats par backend
Write-Log "`n--- RÉCAPITULATIF DES CERTIFICATS PAR BACKEND ---" "INFO" "Yellow"
foreach ($backend in $Backends) {
    $fqdn = "$backend.$Domain"
    $backendResults = $AllResults | Where-Object { $_.Backend -eq $fqdn }
    
    if ($backendResults.Count -eq 0) {
        Write-Log "  ⚠️ $fqdn : Aucun résultat" "WARNING" "Yellow"
        continue
    }
    
    $hashes = $backendResults | Select-Object -ExpandProperty CertificateHash -Unique
    Write-Log "  $fqdn : $($hashes.Count) certificat(s) unique(s)" "INFO" "Gray"
    
    foreach ($hash in $hashes) {
        $binding = $backendResults | Where-Object { $_.CertificateHash -eq $hash } | Select-Object -First 1
        $statusIcon = if ($binding.CertificateStatus -eq "OK") { "✅" } else { "❌" }
        $statusColor = if ($binding.CertificateStatus -eq "OK") { "Green" } else { "Red" }
        Write-Log "    $statusIcon Hash: $($hash.Substring(0,16))..." "INFO" $statusColor
        Write-Log "        Sujet: $($binding.CertificateSubject)" "INFO" "Gray"
        Write-Log "        Expire: $($binding.CertificateExpiry)" "INFO" "Gray"
    }
}

# ==================================================================================================
# SECTION 6 : RAPPORT FINAL
# ==================================================================================================

Write-Log "`n========================================" "INFO" "Cyan"
Write-Log "RAPPORT FINAL" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "  ✅ Backends audités : $SuccessCount" "SUCCESS" "Green"
Write-Log "  ❌ Backends en échec : $FailCount" "ERROR" "Red"
Write-Log "  📊 Bindings HTTPS : $($AllResults.Count)" "INFO" "Cyan"
Write-Log "  ❌ Certificats manquants : $MissingCertCount" "ERROR" "Red"
Write-Log "  📁 CSV exporté : $OutputFile" "INFO" "Gray"
Write-Log "  📄 Log : $LogFile" "INFO" "Gray"

Write-Log "`n✅ Audit terminé" "SUCCESS" "Green"
Write-Log "========================================" "INFO" "Cyan"

Write-Log "`nAppuyez sur Entrée pour fermer..." "INFO" "Yellow"
Read-Host