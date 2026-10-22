<#
    3.3.3.6.Restart-SqlCertificate.ps1
    Objet   : Configurer et vérifier le certificat SSL sur SQLS02.
    Noeuds  : SQLS02
#>

$Hostname = $env:COMPUTERNAME
$CertSubject = "$Hostname.optimedit.eu" # domaine a adapter --------------
$RegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Configuration du certificat SQL Server" -ForegroundColor Cyan
Write-Host " Serveur : $Hostname" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 1. Vérifier le certificat dans LocalMachine\My ---
Write-Host ""
Write-Host "=== 1. Certificat dans LocalMachine\My ===" -ForegroundColor Yellow

$Cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*$CertSubject*" }

if ($Cert) {
    Write-Host "  [OK] Certificat trouvé : $($Cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "  [ECHEC] Certificat introuvable pour $CertSubject" -ForegroundColor Red
    Write-Host "         → Vérifier l'auto-enrôlement du certificat" -ForegroundColor Yellow
    exit 1
}

# --- 2. Vérifier la valeur dans le registre ---
Write-Host ""
Write-Host "=== 2. Valeur 'Certificate' dans le registre ===" -ForegroundColor Yellow

$RegCert = Get-ItemProperty -Path $RegPath -Name "Certificate" -ErrorAction SilentlyContinue

if ($RegCert -and $RegCert.Certificate) {
    Write-Host "  [OK] Certificate = $($RegCert.Certificate)" -ForegroundColor Green

    if ($RegCert.Certificate -eq $Cert.Thumbprint) {
        Write-Host "       [OK] Correspond au certificat dans My" -ForegroundColor Green
    } else {
        Write-Host "       [AVERTISSEMENT] Ne correspond PAS" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ECHEC] Valeur 'Certificate' vide" -ForegroundColor Red
    Write-Host "         → Configurer manuellement via SQL Server Configuration Manager" -ForegroundColor Yellow
    Write-Host "         → Ou exécuter les commandes ci-dessous" -ForegroundColor Yellow
    exit 1
}

# --- 3. Redémarrer SQL Server avec -Force ---
Write-Host ""
Write-Host "=== 3. Redémarrage de SQL Server ===" -ForegroundColor Yellow

Write-Host "  Arrêt de SQL Server..." -ForegroundColor Gray
Stop-Service MSSQLSERVER -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

Write-Host "  Démarrage de SQL Server..." -ForegroundColor Gray
Start-Service MSSQLSERVER
Start-Sleep -Seconds 5

Write-Host "  Démarrage de SQL Server Agent..." -ForegroundColor Gray
Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$SqlStatus = (Get-Service MSSQLSERVER).Status
$AgentStatus = (Get-Service SQLSERVERAGENT).Status

Write-Host "  SQL Server    : $SqlStatus" -ForegroundColor $(if ($SqlStatus -eq "Running") { "Green" } else { "Red" })
Write-Host "  SQL Agent     : $AgentStatus" -ForegroundColor $(if ($AgentStatus -eq "Running") { "Green" } else { "Red" })

# --- 4. Test SSL direct ---
Write-Host ""
Write-Host "=== 4. Test SSL direct ===" -ForegroundColor Yellow

Start-Sleep -Seconds 5

try {
    $TcpClient = New-Object System.Net.Sockets.TcpClient
    $TcpClient.Connect("localhost", 1433)

    $SslStream = New-Object System.Net.Security.SslStream($TcpClient.GetStream(), $false, ({$true}))
    $SslStream.AuthenticateAsClient($CertSubject)

    $PresentedCert = $SslStream.RemoteCertificate

    Write-Host "  Sujet     : $($PresentedCert.Subject)" -ForegroundColor Gray
    Write-Host "  Émetteur  : $($PresentedCert.Issuer)" -ForegroundColor Gray
    Write-Host "  Thumbprint: $($PresentedCert.GetCertHashString())" -ForegroundColor Gray

    if ($PresentedCert.GetCertHashString() -eq $Cert.Thumbprint) {
        Write-Host "  [OK] Certificat présenté = certificat configuré" -ForegroundColor Green
    } else {
        Write-Host "  [AVERTISSEMENT] Certificat présenté différent" -ForegroundColor Yellow
    }

    $SslStream.Close()
    $TcpClient.Close()
} catch {
    Write-Host "  [ECHEC] $($_.Exception.Message)" -ForegroundColor Red
}

# --- 5. Test de connexion SQL Server ---
Write-Host ""
Write-Host "=== 5. Connexion SQL Server (chiffrée) ===" -ForegroundColor Yellow

$ConnectionString = "Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"

try {
    Import-Module SqlServer -ErrorAction SilentlyContinue
    $Result = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query "SELECT SERVERPROPERTY('Edition') AS Edition" -ErrorAction Stop
    Write-Host "  [OK] Connexion réussie : $($Result.Edition)" -ForegroundColor Green
} catch {
    Write-Host "  [ECHEC] $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Configuration terminée." -ForegroundColor Cyan