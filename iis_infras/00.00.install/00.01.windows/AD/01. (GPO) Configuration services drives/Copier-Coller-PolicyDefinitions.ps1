# On définit la source et la destination
$Domaine = "optimedit.eu"

$Source = "C:\Windows\PolicyDefinitions"
$Destination = "C:\Windows\SYSVOL\sysvol\$Domaine\Policies"

# Copie récursive
Copy-Item -Path $Source -Destination $Destination -Recurse -Force -Verbose