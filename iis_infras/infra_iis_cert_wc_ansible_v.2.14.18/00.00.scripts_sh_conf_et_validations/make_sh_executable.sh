#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.audit_winrm_certs/00.00.scripts_sh_conf_et_validations
# Fichier      : make_sh_executable.sh
# Date : 29/05/2026
# DESCRIPTION : Rend TOUS les scripts .sh du projet exécutables pour le groupe
# USAGE       : sudo ./make_sh_executable.sh
# ==============================================================================

BASE_DIR="/projet_optimedit/Git"

echo "🕒 Début de l'activation des droits d'exécution..."

if [ -d "$BASE_DIR" ]; then
    # Recherche et applique le bit +x pour le propriétaire et le groupe
    find "$BASE_DIR" -name "*.sh" -exec chmod ug+x {} +
    echo "✅ [OK] Tous les scripts .sh dans $BASE_DIR sont désormais exécutables !"
    
    # Affichage de contrôle pour tes fichiers iis
    echo -e "\n🔍 Vérification des scripts IIS :"
    ls -al $BASE_DIR/06.03.iis*
else
    echo "❌ Erreur : Le répertoire $BASE_DIR n'existe pas."
fi
