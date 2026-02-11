#!/bin/bash
# Script complet : Nettoyage + Déplacement Docker + Installation SQL Server
# Pour les situations d'espace disque critique

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

clear
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     INSTALLATION SQL SERVER - ESPACE DISQUE CRITIQUE     ║"
echo "║                                                           ║"
echo "║  Ce script va :                                           ║"
echo "║  1. Nettoyer votre système (libère 1-2 GB)              ║"
echo "║  2. Déplacer Docker vers /home (libère 3-4 GB)          ║"
echo "║  3. Installer et configurer SQL Server 2022              ║"
echo "║  4. Télécharger et restaurer AdventureWorks2022         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Vérifier l'espace actuel
echo "📊 ESPACE DISQUE ACTUEL :"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
df -h / /home | grep -E "Filesystem|/dev"
echo ""

ROOT_AVAILABLE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
HOME_AVAILABLE=$(df -BG /home | awk 'NR==2 {print $4}' | sed 's/G//')

print_info "Partition / : ${ROOT_AVAILABLE}GB libres"
print_info "Partition /home : ${HOME_AVAILABLE}GB libres"
echo ""

# Vérifier si /home a assez d'espace
if [ "$HOME_AVAILABLE" -lt 5 ]; then
    print_error "Pas assez d'espace sur /home (besoin de 5GB minimum)"
    exit 1
fi

# Demander confirmation
print_warning "Cette opération va modifier votre système."
print_info "Temps estimé : 20-25 minutes"
echo ""
read -p "Voulez-vous continuer ? (o/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Oo]$ ]]; then
    echo "Annulé."
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  PHASE 1/4 : NETTOYAGE DU SYSTÈME"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Nettoyage APT
print_info "Nettoyage du cache APT..."
sudo apt clean >/dev/null 2>&1
sudo apt autoclean >/dev/null 2>&1
print_success "Cache APT nettoyé"

# Suppression des paquets inutiles
print_info "Suppression des paquets inutiles..."
sudo apt autoremove -y --purge >/dev/null 2>&1
print_success "Paquets inutiles supprimés"

# Nettoyage des logs
print_info "Nettoyage des logs système..."
sudo journalctl --vacuum-time=1d >/dev/null 2>&1
print_success "Logs système nettoyés"

# Cache utilisateur
print_info "Nettoyage du cache utilisateur..."
rm -rf ~/.cache/* 2>/dev/null
rm -rf ~/.local/share/Trash/* 2>/dev/null
print_success "Cache utilisateur nettoyé"

# Fichiers temporaires
print_info "Nettoyage des fichiers temporaires..."
sudo rm -rf /tmp/* 2>/dev/null
sudo rm -rf /var/tmp/* 2>/dev/null
print_success "Fichiers temporaires nettoyés"

# Docker
if command -v docker &> /dev/null; then
    print_info "Nettoyage Docker..."
    sudo docker container prune -f >/dev/null 2>&1
    sudo docker image prune -f >/dev/null 2>&1
    sudo docker builder prune -f >/dev/null 2>&1
    print_success "Docker nettoyé"
fi

echo ""
echo "📊 Espace après nettoyage :"
df -h / | grep -E "Filesystem|/dev"
echo ""

sleep 2

echo "═══════════════════════════════════════════════════════════"
echo "  PHASE 2/4 : DÉPLACEMENT DE DOCKER VERS /HOME"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ -L "/var/lib/docker" ]; then
    print_info "Docker est déjà déplacé vers /home"
    print_success "Étape ignorée"
else
    # Arrêter Docker
    print_info "Arrêt de Docker..."
    sudo systemctl stop docker >/dev/null 2>&1
    sudo systemctl stop docker.socket >/dev/null 2>&1
    sleep 2
    print_success "Docker arrêté"

    # Créer le répertoire
    print_info "Création du répertoire /home/docker..."
    sudo mkdir -p /home/docker
    print_success "Répertoire créé"

    # Copier les données
    if [ -d "/var/lib/docker" ]; then
        DOCKER_SIZE=$(sudo du -sh /var/lib/docker 2>/dev/null | awk '{print $1}')
        print_info "Copie des données Docker (${DOCKER_SIZE})..."
        print_warning "Cela peut prendre plusieurs minutes, veuillez patienter..."
        sudo rsync -a /var/lib/docker/ /home/docker/ >/dev/null 2>&1
        print_success "Données copiées"
    fi

    # Créer le lien symbolique
    print_info "Création du lien symbolique..."
    sudo mv /var/lib/docker /var/lib/docker.old 2>/dev/null || true
    sudo ln -s /home/docker /var/lib/docker
    print_success "Lien créé : /var/lib/docker -> /home/docker"

    # Redémarrer Docker
    print_info "Redémarrage de Docker..."
    sudo systemctl start docker
    sleep 3
    print_success "Docker redémarré"

    # Vérifier
    if sudo systemctl is-active --quiet docker; then
        print_success "Docker fonctionne correctement"
    else
        print_error "Erreur au redémarrage de Docker"
        exit 1
    fi
fi

echo ""
echo "📊 Nouvel espace :"
df -h / /home | grep -E "Filesystem|/dev"
echo ""

sleep 2

echo "═══════════════════════════════════════════════════════════"
echo "  PHASE 3/4 : INSTALLATION SQL SERVER 2022"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Demander le mot de passe
echo "Configuration SQL Server :"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Entrez un mot de passe pour SQL Server"
echo "(min 8 caractères, avec majuscule, chiffre, et caractère spécial)"
echo ""
read -s -p "Mot de passe : " SQL_PASSWORD
echo ""
read -s -p "Confirmez : " SQL_PASSWORD_CONFIRM
echo ""
echo ""

if [ "$SQL_PASSWORD" != "$SQL_PASSWORD_CONFIRM" ]; then
    print_error "Les mots de passe ne correspondent pas"
    exit 1
fi

if [ ${#SQL_PASSWORD} -lt 8 ]; then
    print_error "Le mot de passe doit faire au moins 8 caractères"
    exit 1
fi

print_success "Mot de passe configuré"
echo ""

# Vérifier si le conteneur existe déjà
if sudo docker ps -a | grep -q sqlserver-bi; then
    print_info "Un conteneur sqlserver-bi existe déjà"
    sudo docker stop sqlserver-bi 2>/dev/null || true
    sudo docker rm sqlserver-bi 2>/dev/null || true
fi

# Vérifier si l'image existe
if ! sudo docker images | grep -q "mssql/server"; then
    print_info "Téléchargement de SQL Server 2022 (~1.5 GB)..."
    print_warning "Cela peut prendre quelques minutes..."
    sudo docker pull mcr.microsoft.com/mssql/server:2022-latest
    print_success "Image téléchargée"
else
    print_info "Image SQL Server déjà présente"
fi

# Lancer SQL Server
print_info "Lancement de SQL Server..."
sudo docker run -e "ACCEPT_EULA=Y" \
  -e "MSSQL_SA_PASSWORD=$SQL_PASSWORD" \
  -p 1433:1433 \
  --name sqlserver-bi \
  --hostname sqlserver \
  -d mcr.microsoft.com/mssql/server:2022-latest >/dev/null 2>&1

print_success "Conteneur lancé"

# Attendre que SQL Server soit prêt
print_info "Attente du démarrage de SQL Server (30 secondes)..."
sleep 30
print_success "SQL Server est prêt"

echo ""

echo "═══════════════════════════════════════════════════════════"
echo "  PHASE 4/4 : INSTALLATION D'ADVENTUREWORKS"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Créer le dossier de travail
mkdir -p ~/BI_databases
cd ~/BI_databases

# Télécharger AdventureWorks
if [ ! -f "AdventureWorks2022.bak" ]; then
    print_info "Téléchargement d'AdventureWorks2022 (~200 MB)..."
    wget -q --show-progress https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak
    print_success "Téléchargement terminé"
else
    print_info "AdventureWorks2022.bak déjà présent"
fi

# Copier dans le conteneur
print_info "Copie dans le conteneur Docker..."
sudo docker cp AdventureWorks2022.bak sqlserver-bi:/var/opt/mssql/data/
print_success "Fichier copié"

# Installer sqlcmd si nécessaire
if ! command -v sqlcmd &> /dev/null; then
    print_info "Installation de sqlcmd..."
    curl -s https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc >/dev/null
    UBUNTU_VERSION=$(lsb_release -rs)
    curl -s https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list >/dev/null
    sudo apt update -qq
    sudo ACCEPT_EULA=Y apt install -y mssql-tools18 unixodbc-dev >/dev/null 2>&1
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
    export PATH="$PATH:/opt/mssql-tools18/bin"
    print_success "sqlcmd installé"
else
    print_info "sqlcmd déjà installé"
fi

# Restaurer la base
print_info "Restauration de la base AdventureWorks..."
cat > /tmp/restore.sql << EOF
RESTORE DATABASE AdventureWorks2022
FROM DISK = '/var/opt/mssql/data/AdventureWorks2022.bak'
WITH MOVE 'AdventureWorks2022' TO '/var/opt/mssql/data/AdventureWorks2022.mdf',
     MOVE 'AdventureWorks2022_log' TO '/var/opt/mssql/data/AdventureWorks2022_log.ldf',
     REPLACE
GO
EOF

/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SQL_PASSWORD" -C -i /tmp/restore.sql >/dev/null 2>&1
rm /tmp/restore.sql

print_success "Base AdventureWorks2022 restaurée"

# Test de connexion
TEST_RESULT=$(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SQL_PASSWORD" -d AdventureWorks2022 -C -Q "SELECT COUNT(*) FROM Sales.SalesOrderHeader" -h -1 -W 2>/dev/null | tr -d '[:space:]')

if [ ! -z "$TEST_RESULT" ]; then
    print_success "Test de connexion réussi"
    print_info "Nombre de commandes : $TEST_RESULT"
else
    print_error "Erreur de connexion"
    exit 1
fi

# Créer l'alias
ALIAS_CMD="alias sqlbi='/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"$SQL_PASSWORD\" -d AdventureWorks2022 -C'"
if ! grep -q "alias sqlbi=" ~/.bashrc; then
    echo "$ALIAS_CMD" >> ~/.bashrc
fi

# Créer le fichier de config
cat > ~/BI_databases/config.txt << EOF
═════════════════════════════════════════════
  Configuration SQL Server - BI
═════════════════════════════════════════════

Serveur       : localhost
Port          : 1433
Utilisateur   : sa
Mot de passe  : $SQL_PASSWORD
Base          : AdventureWorks2022

Se connecter :
--------------
source ~/.bashrc
sqlbi

Commandes utiles :
------------------
# Démarrer SQL Server
sudo docker start sqlserver-bi

# Arrêter SQL Server
sudo docker stop sqlserver-bi

# Logs
sudo docker logs sqlserver-bi

# Alterner avec Oracle
sudo docker stop oracle-xe && sudo docker start sqlserver-bi
sudo docker stop sqlserver-bi && sudo docker start oracle-xe

═════════════════════════════════════════════
EOF

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              ✅ INSTALLATION TERMINÉE !                   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📊 RÉSUMÉ :"
echo "━━━━━━━━━━"
print_success "SQL Server 2022 : Installé et fonctionnel"
print_success "AdventureWorks2022 : Base restaurée"
print_success "sqlcmd : Client installé"
print_success "Docker : Déplacé vers /home"
echo ""

echo "📊 Nouvel espace disque :"
df -h / /home | grep -E "Filesystem|/dev"
echo ""

echo "🚀 POUR COMMENCER :"
echo "━━━━━━━━━━━━━━━━━━"
echo "1. Recharger .bashrc :"
echo "   source ~/.bashrc"
echo ""
echo "2. Se connecter :"
echo "   sqlbi"
echo ""
echo "3. Tester une requête :"
echo "   SELECT TOP 5 * FROM Sales.SalesOrderHeader;"
echo "   GO"
echo ""

echo "📝 Configuration sauvegardée dans :"
echo "   ~/BI_databases/config.txt"
echo ""

print_info "Pour supprimer l'ancien Docker (après vérification) :"
echo "   sudo rm -rf /var/lib/docker.old"
echo ""

print_success "Vous êtes prêt pour le TP ! 🎉"
echo ""
