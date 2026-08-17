<# 
    Script : 1.4.2.Update-DNS-OptimeditSites-RP.ps1
    Objectif : Recréer les entrées DNS des 13 sites vers OPT-RP-01
    Auteur : Driss / Optimedit
    Version : 1.0
#>

$zone = "optimedit.eu"
$rpIP = "192.168.3.200"
$log = "C:\Logs\Update-DNS-Sites.log"

if (!(Test-Path "C:\Logs")) { New-Item -ItemType Directory -Path "C:\Logs" -Force }

function Log {
    param([string]$msg)
    Add-Content -Path $log -Value "$(Get-Date) - $msg"
}

$sites = @(
    "achat","blog","ce","client","commercial","comptabilite",
    "direction","formation","it","juridique","paie","production","rh"
)

foreach ($s in $sites) {

    $fqdn = "$s.$zone"

    Log "Traitement de $fqdn"

    # Supprimer l'entrée existante
    try {
        Remove-DnsServerResourceRecord -ZoneName $zone -RRType "A" -Name $s -Force -ErrorAction Stop
        Log "Entrée A supprimée : $fqdn"
    }
    catch {
        Log "Aucune entrée existante pour $fqdn"
    }

    # Créer la nouvelle entrée
    Add-DnsServerResourceRecordA -Name $s -ZoneName $zone -IPv4Address $rpIP
    Log "Entrée A créée : $fqdn -> $rpIP"
}

Log "Mise à jour DNS terminée."
