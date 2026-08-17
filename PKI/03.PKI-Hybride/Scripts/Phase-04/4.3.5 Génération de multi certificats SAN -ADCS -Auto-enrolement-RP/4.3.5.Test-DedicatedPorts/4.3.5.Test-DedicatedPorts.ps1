# ==================================================================================================
# Nom script : 4.3.5.Test-DedicatedPorts.ps1
# Objet      : Teste la redirection HTTPS vers les ports dédiés sur les backends
# Exécution  : Sur OPT-RP-01 (Reverse-Proxy)
# Auteur     : Optimedit
# Date       : 12/08/2026
#
# DESCRIPTION :
#   Teste la connectivité HTTPS sur les ports dédiés (8060-8072) depuis le RP vers chaque backend.
#   Vérifie que le TLS bridging fonctionne correctement.
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

$Sites = @(
    "achat", "blog", "ce", "client", "commercial", "comptabilite",
    "direction", "formation", "it", "juridique", "paie", "production", "rh"
)

$Ports = @{
    "achat"         = 8068
    "blog"          = 8072
    "ce"            = 8064
    "client"        = 8070
    "commercial"    = 8069
    "comptabilite"  = 8061
    "direction"     = 8060
    "formation"     = 8067
    "it"            = 8065
    "juridique"     = 8071
    "paie"          = 8062
    "production"    = 8066
    "rh"            = 8063
}

$LogPath = "C:\Scripts\ADCS\logs"
$LogFile = "$LogPath\Test-DedicatedPorts-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

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

function Test-HttpsUrl {
    param(
        [string]$Url,
        [int]$Timeout = 5
    )
    
    try {
        # Désactiver temporairement la validation du certificat pour le test
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = $Timeout * 1000
        $request.Method = "HEAD"
        $request.UserAgent = "Optimedit-Test/1.0"
        
        $response = $request.GetResponse()
        $statusCode = $response.StatusCode
        $response.Close()
        
        return @{
            Success = $true
            StatusCode = $statusCode
            StatusDescription = $response.StatusDescription
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            StatusCode = $null
            StatusDescription = $null
        }
    }
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

function Test-FromBackend {
    param(
        [string]$ComputerName,
        [string]$SiteName,
        [int]$Port
    )
    
    $scriptBlock = {
        param([string]$SiteName, [int]$Port, [string]$Domain)
        
        $url = "https://$SiteName.$Domain`:$Port/"
        $result = @{ Url = $url; Success = $false; Error = $null }
        
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            
            $request = [System.Net.HttpWebRequest]::Create($url)
            $request.Timeout = 5000
            $request.Method = "HEAD"
            $response = $request.GetResponse()
            $result.Success = $true
            $result.StatusCode = $response.StatusCode
            $response.Close()
        } catch {
            $result.Error = $_.Exception.Message
        }
        
        return $result
    }
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $SiteName, $Port, $Domain -ErrorAction Stop
        Remove-PSSession $session
        return $result
    } catch {
        return @{ Url = "https://$SiteName.$Domain`:$Port/"; Success = $false; Error = "WinRM: $($_.Exception.Message)" }
    }
}

# ==================================================================================================
# SECTION 3 : MAIN
# ==================================================================================================

Write-Log "========================================" "INFO" "Cyan"
Write-Log "TEST PORTS DÉDIÉS - TLS BRIDGING" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO" "Gray"
Write-Log "Backends : $($Backends.Count)" "INFO" "Gray"
Write-Log "Sites : $($Sites.Count)" "INFO" "Gray"
Write-Log "========================================" "INFO" "Cyan"

$totalTests = 0
$successTests = 0
$failedTests = 0
$results = @()

# --------------------------------------------------------------------------------
# TEST 1 : Depuis le RP (vérification que les bindings répondent)
# --------------------------------------------------------------------------------
Write-Log "`n--- TEST DEPUIS LE RP ---" "INFO" "Yellow"

foreach ($site in $Sites) {
    $port = $Ports[$site]
    $url = "https://$site.$Domain`:$port/"
    
    Write-Log "  Test de $url..." "INFO" "Gray"
    $result = Test-HttpsUrl -Url $url -Timeout 5
    
    if ($result.Success) {
        Write-Log "    ✅ $site : HTTP $($result.StatusCode)" "SUCCESS" "Green"
        $successTests++
        $results += [PSCustomObject]@{ Source = "RP"; Site = $site; Port = $port; Status = "OK"; StatusCode = $result.StatusCode }
    } else {
        Write-Log "    ❌ $site : $($result.Error)" "ERROR" "Red"
        $failedTests++
        $results += [PSCustomObject]@{ Source = "RP"; Site = $site; Port = $port; Status = "FAILED"; Error = $result.Error }
    }
    $totalTests++
}

# --------------------------------------------------------------------------------
# TEST 2 : Depuis chaque backend (vérification de la redirection ARR)
# --------------------------------------------------------------------------------
Write-Log "`n--- TEST DEPUIS LES BACKENDS (Redirection ARR) ---" "INFO" "Yellow"

# Tester uniquement le site direction sur chaque backend (représentatif)
$testSite = "direction"
$testPort = $Ports[$testSite]

foreach ($backend in $Backends) {
    $fqdn = "$backend.$Domain"
    $url = "https://$testSite.$Domain`:$testPort/"
    
    Write-Log "  Test depuis $fqdn vers $url..." "INFO" "Gray"
    
    # Test WinRM
    if (-not (Test-WinRMConnection -ComputerName $fqdn)) {
        Write-Log "    ❌ Connexion WinRM impossible sur $fqdn" "ERROR" "Red"
        $failedTests++
        $results += [PSCustomObject]@{ Source = $fqdn; Site = $testSite; Port = $testPort; Status = "FAILED"; Error = "WinRM impossible" }
        $totalTests++
        continue
    }
    
    $result = Test-FromBackend -ComputerName $fqdn -SiteName $testSite -Port $testPort
    
    if ($result.Success) {
        Write-Log "    ✅ $backend : HTTP $($result.StatusCode)" "SUCCESS" "Green"
        $successTests++
        $results += [PSCustomObject]@{ Source = $fqdn; Site = $testSite; Port = $testPort; Status = "OK"; StatusCode = $result.StatusCode }
    } else {
        Write-Log "    ❌ $backend : $($result.Error)" "ERROR" "Red"
        $failedTests++
        $results += [PSCustomObject]@{ Source = $fqdn; Site = $testSite; Port = $testPort; Status = "FAILED"; Error = $result.Error }
    }
    $totalTests++
}

# --------------------------------------------------------------------------------
# RAPPORT FINAL
# --------------------------------------------------------------------------------
Write-Log "`n========================================" "INFO" "Cyan"
Write-Log "RAPPORT FINAL" "INFO" "Cyan"
Write-Log "========================================" "INFO" "Cyan"
Write-Log "  ✅ Succès : $successTests" "SUCCESS" "Green"
Write-Log "  ❌ Échecs : $failedTests" "ERROR" "Red"
Write-Log "  📊 Total : $totalTests" "INFO" "Cyan"

if ($failedTests -eq 0) {
    Write-Log "`n  🎉 TOUS LES TESTS SONT RÉUSSIS !" "SUCCESS" "Green"
    Write-Log "  Le TLS bridging fonctionne parfaitement." "SUCCESS" "Green"
    Write-Log "  Les ports dédiés redirigent correctement vers les backends." "SUCCESS" "Green"
} else {
    Write-Log "`n  ⚠️ $failedTests échec(s) détecté(s)." "WARNING" "Yellow"
    Write-Log "  Vérifiez les bindings sur les backends concernés." "WARNING" "Yellow"
}

Write-Log "`n  📁 Log : $LogFile" "INFO" "Gray"
Write-Log "`n✅ Script terminé" "SUCCESS" "Green"
Write-Log "========================================" "INFO" "Cyan"

Write-Log "`nAppuyez sur Entrée pour fermer..." "INFO" "Yellow"
Read-Host