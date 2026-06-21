# Script d'Audit des certificats WinRM - Version Optimisée
# a executer sur Windows , ex DC
$Servers = @("OPT-IIS-01", "OPT-IIS-02", "OPT-IIS-03")
$Report = @()

Write-Host "--- Lancement de l'audit de santé WinRM HTTPS ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Vérification de $Server..." -ForegroundColor White
    
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        try {
            $res = Invoke-Command -ComputerName $Server -ScriptBlock {
                # Recherche silencieuse du certificat
                $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { 
                    $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
                    if ($null -ne $templateExt) { $templateExt.Format(0) -match "Ansible-WinRM-FQDN" }
                } | Select-Object -First 1

                # Vérification du listener sans générer d'erreur si vide
                $winrmThumb = (Get-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue).CertificateThumbprint

                return [PSCustomObject]@{
                    ServerName      = $env:COMPUTERNAME
                    Status          = "En ligne"
                    FQDN_Cert       = if ($cert) { $cert.Subject.Replace("CN=","") } else { "MANQUANT" }
                    Thumbprint      = if ($cert) { $cert.Thumbprint } else { "N/A" }
                    ExpirationDate  = if ($cert) { $cert.NotAfter } else { "N/A" }
                    WinRM_Correct   = if ($cert -and ($winrmThumb -eq $cert.Thumbprint)) { "OUI" } else { "NON" }
                }
            } -ErrorAction Stop
            $Report += $res
        } catch {
            Write-Host "  [!] Erreur de communication avec $Server" -ForegroundColor Yellow
        }
    } else {
        $Report += [PSCustomObject]@{ ServerName = $Server; Status = "HORS LIGNE"; FQDN_Cert = "N/A"; Thumbprint = "N/A"; ExpirationDate = "N/A"; WinRM_Correct = "N/A" }
    }
}

# Affichage clair
$Report | Format-Table ServerName, Status, WinRM_Correct, ExpirationDate, FQDN_Cert -AutoSize

# Export CSV propre pour ton suivi de projet
$PathCSV = "C:\Scripts\Audit_WinRM_$(Get-Date -Format 'yyyyMMdd').csv"
$Report | Export-Csv -Path $PathCSV -NoTypeInformation -Delimiter ";" -Encoding UTF8
Write-Host "`nRapport final exporté : $PathCSV" -ForegroundColor Green


Import-Csv -Path $PathCSV -Delimiter ";" | Select-Object FQDN_Cert, Status, Thumbprint, WinRM_Correct, ExpirationDate | Format-Table -AutoSize

# sur Ansible avec ectte commande on peut recuperer Thumbprint de crtificat HTTPS connecté en WinRM (5986) - pour un seul serveur:
# echo | openssl s_client -connect opt-iis-01.optimedit.eu:5986 2>/dev/null | openssl x509 -noout -fingerprint -sha1 | awk -F'=' '{print $2}' | sed 's/://g'