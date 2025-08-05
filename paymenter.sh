#!/usr/bin/env bash

# Script de correction d'installation Paymenter
# Ce script corrige le problème des avertissements de dépréciation MariaDB

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # Pas de couleur

echo -e "${GREEN}Démarrage de la correction d'installation Paymenter...${NC}"

# Vérifier si nous sommes dans un conteneur
if [ ! -f /.dockerenv ] && [ ! -d /proc/vz ]; then
    echo -e "${RED}Ce script doit être exécuté dans le conteneur LXC.${NC}"
    echo "Veuillez d'abord entrer dans le conteneur : pct enter 112"
    exit 1
fi

# Fonction pour exécuter des commandes avec gestion d'erreur appropriée
run_cmd() {
    local cmd="$1"
    local desc="$2"
    
    echo -e "${YELLOW}${desc}...${NC}"
    
    if eval "$cmd" 2>/dev/null; then
        echo -e "${GREEN}✓ ${desc} terminé avec succès${NC}"
        return 0
    else
        echo -e "${RED}✗ ${desc} a échoué${NC}"
        return 1
    fi
}

# Vérifier si MariaDB est installé et en cours d'exécution
if ! systemctl is-active --quiet mariadb; then
    echo -e "${YELLOW}Démarrage du service MariaDB...${NC}"
    systemctl start mariadb
    systemctl enable mariadb
fi

# Attendre que MySQL soit prêt
sleep 3

# Créer la base de données et l'utilisateur pour Paymenter si ils n'existent pas
DB_NAME="paymenter"
DB_USER="paymenter"
DB_PASS=$(openssl rand -base64 32)

echo -e "${YELLOW}Configuration de la base de données...${NC}"

# Utiliser mariadb au lieu de la commande mysql dépréciée
mariadb -u root << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Configuration de la base de données terminée${NC}"
else
    echo -e "${RED}✗ Configuration de la base de données échouée${NC}"
    exit 1
fi

# Vérifier si le répertoire Paymenter existe
if [ ! -d "/opt/paymenter" ]; then
    echo -e "${RED}Répertoire Paymenter introuvable. Veuillez vous assurer que l'installation principale est terminée.${NC}"
    exit 1
fi

cd /opt/paymenter

# Créer ou mettre à jour le fichier .env
if [ -f .env ]; then
    echo -e "${YELLOW}Mise à jour du fichier .env existant...${NC}"
else
    echo -e "${YELLOW}Création du fichier .env...${NC}"
    cp .env.example .env
fi

# Mettre à jour la configuration de la base de données dans .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

# Générer la clé d'application si elle n'existe pas
if ! grep -q "APP_KEY=base64:" .env; then
    run_cmd "php artisan key:generate --force" "Génération de la clé d'application"
fi

# Exécuter les migrations de base de données
run_cmd "php artisan migrate --force" "Exécution des migrations de base de données"

# Exécuter les seeders de base de données
run_cmd "php artisan db:seed --force" "Peuplement de la base de données"

# Définir les permissions appropriées
chown -R www-data:www-data /opt/paymenter
chmod -R 755 /opt/paymenter
chmod -R 775 /opt/paymenter/storage
chmod -R 775 /opt/paymenter/bootstrap/cache

# Démarrer et activer nginx s'il n'est pas déjà en cours d'exécution
if ! systemctl is-active --quiet nginx; then
    systemctl start nginx
    systemctl enable nginx
fi

# Démarrer et activer PHP-FPM
systemctl start php8.3-fpm
systemctl enable php8.3-fpm

echo -e "${GREEN}=== Correction d'installation Paymenter terminée ===${NC}"
echo -e "${GREEN}Nom de la base de données : ${DB_NAME}${NC}"
echo -e "${GREEN}Utilisateur de la base de données : ${DB_USER}${NC}"
echo -e "${YELLOW}Mot de passe de la base de données : ${DB_PASS}${NC}"
echo -e "${YELLOW}Veuillez sauvegarder ces identifiants en sécurité !${NC}"

# Obtenir l'IP du conteneur
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
echo -e "${GREEN}Accéder à Paymenter via : http://${IP}${NC}"