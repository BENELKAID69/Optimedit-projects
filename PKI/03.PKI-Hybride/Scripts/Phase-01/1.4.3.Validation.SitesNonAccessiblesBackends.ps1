<# 
    Script : 1.4.3.Validation.SitesNonAccessiblesBackends.ps1
    Objectif : Vérifier que les sites NE répondent PAS directement depuis les backends
    Auteur : Driss / Optimedit
    Version : 1.0

    IMPORTANT
    CE SCRIPT NE DOIT PAS ÊTRE EXÉCUTÉ SUR LE REVERSE-PROXY OPT-RP-01.
    Pourquoi ?
      - OPT-RP-01 est autorisé dans le firewall des backends.
      - Donc OPT-RP-01 peut accéder directement aux backends (normal).
      - Ce test doit être fait depuis un poste LAN/VPN NON autorisé.
#>

Write-Host "===== TEST — VALIDATION : Sites NON accessibles depuis les backends =====" -ForegroundColor Cyan
Write-Host "Ce test doit être exécuté depuis un poste LAN/VPN NON OPT-RP-01" -ForegroundColor Yellow

# ============================================================
# Configuration
# ============================================================

$Backends = @(
    "OPT-IIS-01.optimedit.eu",
    "OPT-IIS-02.optimedit.eu",
    "OPT-IIS-03.optimedit.eu",
    "OPT-IIS-04.optimedit.eu",
    "OPT-IIS-05.optimedit.eu",
    "OPT-IIS-06.optimedit.eu"
)

$Sites = @(
    "achat","blog","ce","client","commercial","comptabilite",
    "direction","formation","it","juridique","paie","production","rh"
)

# ============================================================
# Test : Les sites NE doivent PAS répondre depuis les backends
# ============================================================

Write-Host "`n--- TEST : Vérifier que les sites ne répondent pas depuis les backends ---" -ForegroundColor Yellow

foreach ($s in $Sites) {
    foreach ($b in $Backends) {

        $fqdn = "$s.optimedit.eu"

        try {
            # On interroge le backend directement avec le host-header du site
            Invoke-WebRequest -Uri "http://$b" -Headers @{Host=$fqdn} -UseBasicParsing -TimeoutSec 3

            # Si ça répond → ERREUR (depuis LAN)
            Write-Host "ERREUR : $fqdn répond depuis $b (ne devrait pas)" -ForegroundColor Red
        }
        catch {
            # Si ça ne répond pas → OK (depuis LAN)
            Write-Host "OK : $fqdn ne répond pas depuis $b (normal)" -ForegroundColor Green
        }
    }
}

Write-Host "`n===== TEST TERMINÉ =====" -ForegroundColor Cyan
