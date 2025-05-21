# Charger le fichier .env
include .env

DC=docker compose exec wordpress
DC_WP=docker compose exec wordpress wp

.PHONY: autoinstall build up healthcheck install rsync-db rsync-content down clean reset

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


# 📦 Synchronise la base de données distante vers l'environnement local
rsync-db:
	@echo "🔄 Export de la base distante..."
	ssh -p $(REMOTE_SSH_PORT) $(REMOTE_SSH_USER)@$(REMOTE_SSH_HOST) "cd $(REMOTE_PROJECT_PATH) && wp db export --add-drop-table $(REMOTE_DB_FILE)"

	@echo "📥 Récupération du fichier SQL..."
	rsync -e "ssh -p $(REMOTE_SSH_PORT)" $(REMOTE_SSH_USER)@$(REMOTE_SSH_HOST):$(REMOTE_PROJECT_PATH)/$(REMOTE_DB_FILE) $(LOCAL_PATH)/$(REMOTE_DB_FILE)

	@echo "🧹 Suppression du dump SQL distant..."
	ssh -p $(REMOTE_SSH_PORT) $(REMOTE_SSH_USER)@$(REMOTE_SSH_HOST) "rm $(REMOTE_PROJECT_PATH)/$(REMOTE_DB_FILE)"

	@echo "🔎 Récupération du préfixe distant..."
	$(eval REMOTE_PREFIX := $(shell ssh -p $(REMOTE_SSH_PORT) $(REMOTE_SSH_USER)@$(REMOTE_SSH_HOST) "cd $(REMOTE_PROJECT_PATH) && wp db prefix"))

	@echo "🛠️ Mise à jour du préfixe dans le fichier .env..."
	sed -i.bak "s/^WORDPRESS_TABLE_PREFIX=.*/WORDPRESS_TABLE_PREFIX=$(REMOTE_PREFIX)/" .env

	@echo "💣 Réinitialisation de la base locale..."
	$(DC_WP) db reset --yes

	@echo "📦 Import de la base distante..."
	$(DC_WP) db import $(REMOTE_DB_FILE)

	@echo "🧹 Suppression du dump SQL local..."
	rm $(LOCAL_PATH)/$(REMOTE_DB_FILE)

	@echo "🧼 Nettoyage du .env.bak..."
	rm -f .env.bak

	@echo "🚀 Redémarrage du conteneur WordPress..."
	make down up healthcheck

	@echo "🌐 Remplacement des URLs de $(REMOTE_URL) par $(LOCAL_URL)..."
	$(DC_WP) search-replace '$(REMOTE_URL)' '$(LOCAL_URL)' --skip-columns=guid --precise

	@echo "✅ Synchronisation terminée avec succès !"

rsync-content:
	@echo "🔄 Synchronisation du dossier wp-content..."
#	@EXCLUDES=$$(for y in $$(seq 2012 2024); do echo "--exclude=uploads/$$y"; done); \
#	rsync -av --whole-file $$EXCLUDES
	rsync -av --whole-file \
		--exclude="cache" \
		--exclude="upgrade" \
		--exclude="updraft" \
		--exclude="themes" \
		-e "ssh -p $(REMOTE_SSH_PORT)" \
		$(REMOTE_SSH_USER)@$(REMOTE_SSH_HOST):$(REMOTE_PROJECT_PATH)/wp-content/ \
		$(LOCAL_PATH)/wp-content/
	@echo "✅ Contenu wp-content synchronisé !"


# ⚙️ Accès au container wordpress
bash:
	@docker compose exec wordpress bash -c "cd /var/www/html/wp-content/themes && exec bash"

# 🧹 Stopper les containers
down:
	@echo "\n🛑 Arrêt des services..."
	@docker compose down

# 🧹 Nettoyage des volumes (db_data / wordpress)
clean:
	@echo "\n🧹 Suppression des fichiers et dossiers liés..."
	@docker compose down -v
	@rm -rf wordpress/* && rm -f wordpress/.htaccess 1 > /dev/null 2>&1
	@sudo rm -rf db_data/*

# ♻️ Nettoyage complet (down + suppression)
reset: clean
	@echo "\n♻️  Réinitialisation complète terminée. \n"
