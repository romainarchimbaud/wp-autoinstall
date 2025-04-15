# Charger le fichier .env
include .env

DC=docker compose exec wordpress
DC_WP=docker compose exec wordpress wp

.PHONY: autoinstall build up healthcheck install down clean reset

# 🛠️ Autoinstall wordpress
autoinstall: build healthcheck install

# 🛠️ Build & launch les services
build:
	@echo "\n🔧 Build des services Docker..."
	@docker compose up -d --build

up:
	@echo "\n🚀 Lancement des services..."
	@docker compose up -d

healthcheck:
	@echo "\n🔁 Attente de l'accessibilité des services ..."
	@until curl -s -o /dev/null -w "%{http_code}" `echo ${WORDPRESS_WEBSITE_URL}`/wp-admin/install.php | grep -Eq "200"; do \
		echo "⏳ En attente..."; \
		sleep 2; \
	done; 
	@echo "✅ Services ok ..."

# ⚙️ Installation WordPress avec vérification des variables
install:
	@test -f .env || (echo "❌ Fichier .env introuvable à la racine !" && exit 1)
	@echo "\n⭐ Installation de wordpress..."
	$(DC_WP) core install \
			--url='${WORDPRESS_WEBSITE_URL_WITHOUT_HTTP}' \
			--title=${WORDPRESS_WEBSITE_TITLE} \
			--admin_user='${WORDPRESS_ADMIN_USER}' \
			--admin_password='${WORDPRESS_ADMIN_PASSWORD}' \
			--admin_email='${WORDPRESS_ADMIN_EMAIL}' \
			--locale='${WORDPRESS_LOCALE}'
	
	@$(DC_WP) option update siteurl ${WORDPRESS_WEBSITE_URL}
	@$(DC_WP) rewrite structure $(WORDPRESS_WEBSITE_POST_URL_STRUCTURE)
	
	@echo "\n🌐 Switch wordpress language..."
	@$(DC_WP) language core install fr_FR
	@$(DC_WP) site switch-language fr_FR

	@echo "\n🧹 Removing Wordpress default themes..."
	@$(DC_WP) theme delete `echo ${WORDPRESS_DEFAULT_THEMES}`

	@echo "\n🧹 Removing Wordpress default plugins..."
	@$(DC_WP) plugin delete `echo ${WORDPRESS_DEFAULT_PLUGINS}`
	
	@echo "\n🎨 Installation des thèmes et plugins..."
# Décommenter pour installer les thèmes
#	@$(DC_WP) theme install ${WORDPRESS_REPO_THEMES}
#	@$(DC_WP) language theme install --all ${WORDPRESS_LOCALE}

	@$(DC_WP) plugin install `echo ${WORDPRESS_REPO_PLUGINS}`
	@$(DC_WP) language plugin install --all ${WORDPRESS_LOCALE}

	@echo "\n🧹 Removing Wordpress default posts & pages..."
	@$(DC_WP) post delete --force `echo ${WORDPRESS_DEFAULT_POSTS_PAGES}`

	@echo "\n⭐ Installation de WordPress terminée : ${WORDPRESS_WEBSITE_URL}/wp-admin \n"

# 🧹 Stopper les containers
bash:
	@docker compose exec wordpress bash

# 🧹 Stopper les containers
down:
	@echo "\n🛑 Arrêt des services..."
	@docker compose down

# 🧹 Nettoyage des volumes (mysql / wordpress)
clean: 
	@echo "\n🧹 Suppression des fichiers et dossiers liés..."
	@docker compose down -v
	@rm -rf wordpress/* && rm -f wordpress/.htaccess 1 > /dev/null 2>&1

# ♻️ Nettoyage complet (down + suppression)
reset: clean
	@echo "\n♻️  Réinitialisation complète terminée. \n"
