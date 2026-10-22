<#
    3.1.0.create_storage_directories.ps1
    Objet   : Creer l'arborescence de stockage SQL Server (incl. sous-dossier Audit)
    Noeuds  : SQLS01 + SQLS02 (executer sur chaque noeud localement)
#>

$RootPath = "S:\SQL"
$Folders  = @("Data","Log","Backup","TempDB","Backup\Audit")

foreach ($Folder in $Folders) {
    $Path = Join-Path $RootPath $Folder
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-Host "Dossier cree : $Path" -ForegroundColor Green
    } else {
        Write-Host "Dossier deja present : $Path" -ForegroundColor Yellow
    }
}
