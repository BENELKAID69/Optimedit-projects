#!/bin/bash
# ==============================================================================
# Emplacement : /projets_optimedit/infra_iis_ansible/infra_iis_cert_wc_ansible_v.2.14.18/
# Fichier     : run_all_playbooks.sh
# Version  : 3 - rajout verification kinit
# date : 20/06/2026
# Description : Exécution de tous les Playbooks
# ==============================================================================
# Configuration des couleurs pour l'affichage
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LOG_FILE="deploy_execution.log"

# Sécurité : S'assurer que le fichier est inscriptible par l'utilisateur courant
touch "$LOG_FILE"
sudo chown $(whoami):gr_ansible_admins "$LOG_FILE"
chmod 664 "$LOG_FILE"

echo -e "${BLUE}===================================================================${NC}"
echo -e "${BLUE}    Lancement du Déploiement Complet de l'Infrastructure Wildcard   ${NC}"
echo -e "${BLUE}===================================================================${NC}"
echo "Début de l'exécution : $(date)" > $LOG_FILE

execute_playbook() {
    local playbook_path=$1
    local description=$2

    # Vérification du ticket Kerberos avant chaque exécution
    klist -s
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}[ERREUR CRITIQUE] : Aucun ticket Kerberos valide trouvé pour $(whoami).${NC}"
        echo -e "${RED}Veuillez exécuter 'kinit' avant de relancer le script.${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}[Exécution] : ${description}...${NC}"
    echo "--------------------------------------------------" >> $LOG_FILE
    echo "Playbook: $playbook_path" >> $LOG_FILE
    echo "Début: $(date)" >> $LOG_FILE

    # Forçage de la configuration locale pour les collections
    export ANSIBLE_CONFIG="$(pwd)/ansible.cfg"

    ansible-playbook -i inventory.yml "$playbook_path" >> $LOG_FILE 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK] : ${description} terminé avec succès.${NC}"
        echo "Résultat: SUCCESS" >> $LOG_FILE
    else
        echo -e "${RED}[ERREUR] : Échec lors de ${description}. Vérifiez $LOG_FILE${NC}"
        echo "Résultat: FAILED" >> $LOG_FILE
        echo -e "${RED}Arrêt du script de déploiement.${NC}"
        exit 1
    fi
    echo "Fin: $(date)" >> $LOG_FILE
}

# =========================================================================
# SÉQUENCE DE DÉPLOIEMENT CHRONOLOGIQUE STRICTE
# =========================================================================

# --- ÉTAPE 00 : PROVISIONING PRÉLIMINAIRE ---
echo -e "\n${BLUE}--- Étape 00 : Génération Dynamique du Contexte Externe ---${NC}"
execute_playbook "00.00.play_all_interne_create_host_vars_file.yml" "Génération automatique des fichiers host_vars (IP)"

# --- ÉTAPE 01 : ACTIVE DIRECTORY, DNS & DÉLÉGATION KERBEROS ---
echo -e "\n${BLUE}--- Étape 01 : Configuration Active Directory, DNS & Sécurité ---${NC}"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.01.play_iis_dc_create_users_applications.yml" "Création des comptes de service applicatifs"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.02.play_iis_dc_setup_dns.yml" "Configuration des zones et enregistrements DNS"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.03.play_iis_dc_ad_group.yml" "Création des groupes de sécurité Active Directory"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.04.play_iis_dc_ad_spn.yml" "Déploiement et configuration des SPN HTTP"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.05.play_iis_test_kerberos_delegation_smb_write.yml" "Validation de la chaîne de délégation Kerberos et écriture SMB"
execute_playbook "01.00.plays_ad_dns_delegation_spn/01.07.play_iis_maintenance_audit_applications_SPN_HTTP.yml" "Audit initial de maintenance et validation des SPN HTTP"

# --- ÉTAPE 02 : DEPLOIEMENT DE LA COUCHE IIS HTTP ---
echo -e "\n${BLUE}--- Étape 02 : Installation du Serveur Web IIS & Contenu HTTP ---${NC}"
execute_playbook "02.00.plays_install_iis_pool_http/02.01.play_iis_install_http.yml" "Installation du rôle Web-Server IIS et fonctionnalités"
execute_playbook "02.00.plays_install_iis_pool_http/02.02.play_iis_generate_index.html.yml" "Génération dynamique et injection des pages index.html"

# --- ÉTAPE 03 : SÉCURISATION & DURCISSEMENT HTTPS (443 & PORTS DÉDIÉS) ---
echo -e "\n${BLUE}--- Étape 03 : Chiffrement HTTPS & Isolation des Liaisons SSL ---${NC}"
execute_playbook "03.00.plays_conf_https_443_ports_dedies/03.01.play_iis_flush_ssl_before_config.yml" "Purge préliminaire des liaisons SSL (Flush 443)"
execute_playbook "03.00.plays_conf_https_443_ports_dedies/03.02.play_iis_ssl_https.yml" "Liaison du certificat Wildcard et configuration HTTPS Standard"
execute_playbook "03.00.plays_conf_https_443_ports_dedies/03.03.play_iis_hardening_port_dedies_ssl_flush.yml" "Flush SSL des liaisons sur ports alternatifs"
execute_playbook "03.00.plays_conf_https_443_ports_dedies/03.04.play_iis_hardening_port_dedies_ssl_conf.yml" "Durcissement HTTPS sur les ports dédiés isolés"

# --- ÉTAPE 04 : IDENTITÉS APPLICATIVES DE POOLS & ACL NTFS ---
echo -e "\n${BLUE}--- Étape 04 : Verrouillage des Pools d'Applications & Droits NTFS ---${NC}"
execute_playbook "04.00.plays_pool_indentity_svc_acl_ntfs/04.01.play_iis_hardening_pool_svc.yml" "Basculement des Application Pools sur les identités de service AD"
execute_playbook "04.00.plays_pool_indentity_svc_acl_ntfs/04.02.play_iis_acl_applications.yml" "Application des ACL NTFS restrictives sur les répertoires web"
execute_playbook "04.00.plays_pool_indentity_svc_acl_ntfs/04.03.iis.test_dir_acl_apps_Use_--limit_cible.yml" "Audit de sécurité et validation finale des permissions NTFS"

# --- ÉTAPE 05 : MAINTENANCE, LOGS & POLICY DE RECYCLAGE DES POOLS ---
echo -e "\n${BLUE}--- Étape 05 : Politiques de Recyclage & Audits de Maintenance ---${NC}"
execute_playbook "05.00.plays_pools_recycling_maintenances/05.01.play_iis_maintenance_AHH_AHS_Local_Keys_aspnet_regiis.yml" "Maintenance des clés d'activation et enregistrement ASP.NET IIS"
execute_playbook "05.00.plays_pools_recycling_maintenances/05.02.play_iis_maintenance_enable_recycling_logs.yml" "Activation et redirection des logs de recyclage d'Application Pools"
execute_playbook "05.00.plays_pools_recycling_maintenances/05.03.play_iis_maintenance_configure_nightly_recycle.yml" "Configuration de la planification du recyclage nocturne automatique"
execute_playbook "05.00.plays_pools_recycling_maintenances/05.04.play_iis_audit_pools_recycling_status.yml" "Audit d'état et vérification des configurations de recyclage"
execute_playbook "05.00.plays_pools_recycling_maintenances/05.05.play_iis_audit_was_activity_logs.yml" "Audit de l'activité WAS (Windows Process Activation Service) via l'Event Viewer"

# =========================================================================
# FIN DE L'ORCHESTRATION
# =========================================================================
echo -e "\n${GREEN}===================================================================${NC}"
echo -e "${GREEN}    Déploiement terminé avec succès ! Séquence chronologique OK.    ${NC}"
echo -e "${GREEN}===================================================================${NC}"
echo "Fin globale de l'exécution : $(date)" >> $LOG_FILE
