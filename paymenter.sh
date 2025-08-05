#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Auteur: Nícolas Pastorello (opastorello)
# Licence: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.paymenter.org

APP="Paymenter"
var_tags="${var_tags:-hosting;ecommerce;marketplace;}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-5}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/paymenter ]]; then
    msg_error "Aucune installation ${APP} trouvée !"
    exit
  fi
  
  CURRENT_PHP=$(php -v 2>/dev/null | awk '/^PHP/{print $2}' | cut -d. -f1,2)
  if [[ "$CURRENT_PHP" != "8.3" ]]; then
    msg_info "Migration de PHP $CURRENT_PHP vers 8.3"
    $STD curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    $STD dpkg -i /tmp/debsuryorg-archive-keyring.deb
    $STD sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
    $STD apt-get update
    $STD apt-get remove -y php"${CURRENT_PHP//./}"*
    $STD apt-get install -y \
      php8.3 \
      php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,redis,fpm}
    sed -i 's|php8\.2-fpm\.sock|php8.3-fpm.sock|g' /etc/nginx/sites-available/paymenter.conf
    $STD systemctl reload nginx
    msg_ok "Migration de PHP $CURRENT_PHP vers 8.3 terminée"
  fi
  
  RELEASE=$(curl -fsSL https://api.github.com/repos/paymenter/paymenter/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
  if [[ ! -f /opt/${APP}_version.txt ]] || [[ "${RELEASE}" != "$(cat /opt/${APP}_version.txt)" ]]; then
    msg_info "Mise à jour de ${APP} vers ${RELEASE}"
    echo "${RELEASE}" >/opt/${APP}_version.txt
    cd /opt/paymenter
    $STD php artisan p:upgrade --no-interaction
    msg_ok "Mise à jour réussie"
  else
    msg_ok "Aucune mise à jour requise. ${APP} est déjà en version ${RELEASE}."
  fi
  exit
}

# Fonction pour corriger les problèmes de base de données MariaDB
fix_mariadb_setup() {
  msg_info "Configuration de la base de données MariaDB"
  
  # Vérifier si MariaDB est en cours d'exécution
  if ! systemctl is-active --quiet mariadb; then
    $STD systemctl start mariadb
    $STD systemctl enable mariadb
  fi
  
  # Attendre que MariaDB soit prêt
  sleep 3
  
  # Créer la base de données et l'utilisateur en utilisant mariadb au lieu de mysql
  DB_NAME="paymenter"
  DB_USER="paymenter"
  DB_PASS=$(openssl rand -base64 32)
  
  # Utiliser mariadb au lieu de la commande mysql dépréciée pour éviter les avertissements
  mariadb -u root 2>/dev/null << EOF || mysql -u root 2>/dev/null << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

  if [ $? -eq 0 ]; then
    msg_ok "Configuration de la base de données terminée"
    
    # Mettre à jour le fichier .env s'il existe
    if [ -f /opt/paymenter/.env ]; then
      sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" /opt/paymenter/.env
      sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" /opt/paymenter/.env
      sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" /opt/paymenter/.env
      
      # Sauvegarder les identifiants dans un fichier sécurisé
      cat > /opt/paymenter/database_credentials.txt << EOF
Nom de la base de données: ${DB_NAME}
Utilisateur: ${DB_USER}
Mot de passe: ${DB_PASS}
EOF
      chmod 600 /opt/paymenter/database_credentials.txt
      chown www-data:www-data /opt/paymenter/database_credentials.txt
    fi
  else
    msg_error "Échec de la configuration de la base de données"
    return 1
  fi
}

# Fonction pour finaliser l'installation Paymenter
finalize_paymenter_setup() {
  if [ -d "/opt/paymenter" ]; then
    msg_info "Finalisation de l'installation Paymenter"
    
    cd /opt/paymenter
    
    # Générer la clé d'application si nécessaire
    if [ -f .env ] && ! grep -q "APP_KEY=base64:" .env; then
      $STD php artisan key:generate --force
    fi
    
    # Exécuter les migrations et seeders avec une meilleure gestion d'erreur
    if php artisan migrate --force 2>/dev/null; then
      msg_ok "Migrations de base de données terminées"
    else
      msg_info "Tentative de migration avec paramètres personnalisés"
      fix_mariadb_setup
      $STD php artisan migrate --force
    fi
    
    $STD php artisan db:seed --force 2>/dev/null || true
    
    # Définir les permissions appropriées
    chown -R www-data:www-data /opt/paymenter
    chmod -R 755 /opt/paymenter
    chmod -R 775 /opt/paymenter/storage /opt/paymenter/bootstrap/cache
    
    # S'assurer que les services sont démarrés
    $STD systemctl restart nginx php8.3-fpm
    $STD systemctl enable nginx php8.3-fpm
    
    msg_ok "Installation Paymenter finalisée"
  fi
}

start
custom_build_container
description

start
custom_build_container
description

msg_ok "Installation terminée avec succès !\n"
echo -e "${CREATING}${GN}L'installation de ${APP} a été initialisée avec succès !${CL}"
echo -e "${INFO}${YW} Accédez-y en utilisant l'URL suivante :${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:80${CL}"
echo -e "${INFO}${YW} Les identifiants de base de données sont sauvegardés dans :${CL}"
echo -e "${TAB}${GATEWAY}${BGN}/opt/paymenter/db_info.txt${CL}"