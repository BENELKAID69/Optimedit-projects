<# 
    Script : 1.4.4.Test-LoadBalancing-ARR-AllSites.ps1
    Objectif : Tester la répartition de charge ARR sur les 13 sites
    Auteur : Optimedit
    Version : 1.3
#>

Write-Host "===== TEST LOAD-BALANCING ARR (13 sites, 3 requêtes chacun) =====" -ForegroundColor Cyan

$Sites = @(
    "achat","blog","ce","client","commercial","comptabilite",
    "direction","formation","it","juridique","paie","production","rh"
)

$results = @()

foreach ($s in $Sites) {

    Write-Host "`n--- SITE : $s.optimedit.eu ---" -ForegroundColor Yellow

    $target = "http://$s.optimedit.eu"

    for ($i = 1; $i -le 3; $i++) {

        try {
            $r = Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 3

            # Extraction correcte du backend
            $line = ($r.Content | Select-String "Cible Inventaire Ansible").Line
            $backend = $line -replace ".*Cible Inventaire Ansible : ", "" -replace "</p>", ""

            $results += [PSCustomObject]@{
                Site    = $s
                Requete = $i
                Backend = $backend
            }

            Write-Host "[$s - Req $i] -> $backend" -ForegroundColor Green
        }
        catch {
            Write-Host "[$s - Req $i] -> ERREUR" -ForegroundColor Red
        }
    }
}

Write-Host "`n===== RÉCAPITULATIF GLOBAL =====" -ForegroundColor Cyan

$results | Group-Object Site | ForEach-Object {
    Write-Host "`nSite : $($_.Name)" -ForegroundColor Yellow
    $_.Group | Group-Object Backend | Select-Object Count, Name | Format-Table -AutoSize
}
