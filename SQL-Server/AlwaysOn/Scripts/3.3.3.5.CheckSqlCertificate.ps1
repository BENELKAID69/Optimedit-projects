<#
    3.3.3.5.CheckSqlCertificate.ps1
    Objet   : Vérifier la configuration du certificat SSL de SQL Server.
    Noeuds  : SQLS01 + SQLS02
#>

$Hostname = $env:COMPUTERNAME
$CertSubject = "$Hostname.optimedit.eu"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Vérification du certificat SQL Server" -ForegroundColor Cyan
Write-Host " Serveur : $Hostname" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 1. Vérifier le certificat dans LocalMachine\My ---
Write-Host ""
Write-Host "=== 1. Certificat dans LocalMachine\My ===" -ForegroundColor Yellow

$Cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like "*$CertSubject*" }

if ($Cert) {
    Write-Host "  [OK] Certificat trouvé :" -ForegroundColor Green
    Write-Host "       Sujet     : $($Cert.Subject)" -ForegroundColor Gray
    Write-Host "       Émetteur  : $($Cert.Issuer)" -ForegroundColor Gray
    Write-Host "       Expiration: $($Cert.NotAfter)" -ForegroundColor Gray
    Write-Host "       Thumbprint: $($Cert.Thumbprint)" -ForegroundColor Gray
    Write-Host "       Clé privée: $($Cert.HasPrivateKey)" -ForegroundColor Gray
} else {
    Write-Host "  [ECHEC] Certificat introuvable pour $CertSubject" -ForegroundColor Red
}

# --- 2. Vérifier la valeur dans le registre ---
Write-Host ""
Write-Host "=== 2. Valeur 'Certificate' dans le registre ===" -ForegroundColor Yellow

$RegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"

if (Test-Path $RegPath) {
    $RegValue = Get-ItemProperty -Path $RegPath -Name "Certificate" -ErrorAction SilentlyContinue

    if ($RegValue -and $RegValue.Certificate) {
        Write-Host "  [OK] Certificate = $($RegValue.Certificate)" -ForegroundColor Green

        if ($Cert -and $RegValue.Certificate -eq $Cert.Thumbprint) {
            Write-Host "       [OK] Correspond au certificat dans My" -ForegroundColor Green
        } else {
            Write-Host "       [AVERTISSEMENT] Ne correspond PAS au certificat dans My" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [ECHEC] Valeur 'Certificate' vide ou absente" -ForegroundColor Red
        Write-Host "         → Configurer le certificat dans SQL Server Configuration Manager" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ECHEC] Chemin registre introuvable : $RegPath" -ForegroundColor Red
}

# --- 3. Test SSL direct ---
Write-Host ""
Write-Host "=== 3. Certificat présenté par SQL Server (test SSL) ===" -ForegroundColor Yellow

try {
    $TcpClient = New-Object System.Net.Sockets.TcpClient
    $TcpClient.Connect("localhost", 1433)

    $SslStream = New-Object System.Net.Security.SslStream($TcpClient.GetStream(), $false, ({$true}))
    $SslStream.AuthenticateAsClient($CertSubject)

    $PresentedCert = $SslStream.RemoteCertificate

    Write-Host "  Sujet     : $($PresentedCert.Subject)" -ForegroundColor Gray
    Write-Host "  Émetteur  : $($PresentedCert.Issuer)" -ForegroundColor Gray
    Write-Host "  Thumbprint: $($PresentedCert.GetCertHashString())" -ForegroundColor Gray

    if ($Cert -and $PresentedCert.GetCertHashString() -eq $Cert.Thumbprint) {
        Write-Host "  [OK] Le certificat présenté correspond au certificat configuré" -ForegroundColor Green
    } else {
        Write-Host "  [AVERTISSEMENT] Le certificat présenté ne correspond pas" -ForegroundColor Yellow
    }

    $SslStream.Close()
    $TcpClient.Close()
} catch {
    Write-Host "  [ECHEC] Impossible de récupérer le certificat : $($_.Exception.Message)" -ForegroundColor Red
}

# --- 4. Test de connexion SQL Server ---
Write-Host ""
Write-Host "=== 4. Connexion SQL Server (chiffrée) ===" -ForegroundColor Yellow

$ConnectionString = "Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"

try {
    Import-Module SqlServer -ErrorAction SilentlyContinue
    $Result = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query "SELECT SERVERPROPERTY('Edition') AS Edition" -ErrorAction Stop
    Write-Host "  [OK] Connexion réussie : $($Result.Edition)" -ForegroundColor Green

    # Vérifier le chiffrement
    $EncryptInfo = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query "SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID" -ErrorAction Stop
    Write-Host "  [INFO] Chiffrement : $($EncryptInfo.encrypt_option)" -ForegroundColor Gray
} catch {
    Write-Host "  [ECHEC] Connexion échouée : $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Vérification terminée." -ForegroundColor Cyan