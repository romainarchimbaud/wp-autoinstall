# Charger le fichier .env (absent avant le premier make setup), sauf pour setup/autoinstall :
# make écraserait les variables d'environnement passées à setup (WORDPRESS_ADMIN_EMAIL=… make setup)
ifeq ($(filter setup autoinstall,$(or $(MAKECMDGOALS),autoinstall)),)
-include .env
# Saisies libres : jamais retransmises par make (qui coupe au # et garde les guillemets), Compose les relit dans .env
unexport WORDPRESS_WEBSITE_TITLE WORDPRESS_ADMIN_USER WORDPRESS_ADMIN_EMAIL WORDPRESS_ADMIN_PASSWORD STAGING_URL PROD_URL
endif

# URL locale dérivée du port : jamais écrite ailleurs
LOCAL_URL := http://localhost:$(HTTP_PORT)

# Valeurs fixes (sorties du .env, spec 004)
WORDPRESS_LOCALE := fr_FR
WORDPRESS_WEBSITE_POST_URL_STRUCTURE := /%postname%/
WORDPRESS_DEFAULT_PLUGINS := hello akismet
WORDPRESS_DEFAULT_POSTS_PAGES := 1 2 3
export USER_UID := $(shell id -u)
export USER_GID := $(shell id -g)

DC=docker compose exec wordpress
DC_WP=docker compose exec wordpress wp
# Commande shell dans le conteneur : les saisies libres (titre, identifiant, e-mail, mot de passe)
# y arrivent par l'environnement (compose.yml), jamais par make.
DC_SH=docker compose exec -T wordpress sh -c

.PHONY: autoinstall setup doctor build up healthcheck install bash down clean reset help

# 🛠️  Autoinstall wordpress : toutes les questions d'abord, puis un sous-make qui relit le .env écrit
autoinstall: setup
	@$(MAKE) --no-print-directory doctor build healthcheck install
	@echo "ℹ️  Staging et prod sont seulement déclarés dans .env : rien n'y a été installé."
	@echo "   Pour les relier, quand tu as les accès SSH :"
	@echo "     1. make ssh-alias    crée les alias et vérifie que WordPress répond"
	@echo "     2. make pull-staging récupère le site distant en local"

# 📝 Questionnaire : écrit .env (ports libres choisis automatiquement)
setup:
	@bash scripts/setup.sh

# 🔎 Ports hôte utilisables ? (échoue avant de démarrer quoi que ce soit)
doctor:
	@bash scripts/setup.sh doctor

# 🛠️  Construction et démarrage des services
build:
	@echo "\n🔧 Build des services Docker..."
	@docker compose up -d --build

up: doctor
	@echo "\n🚀 Lancement des services..."
	@docker compose up -d

healthcheck:
	@echo "\n🔁 Attente de l'accessibilité des services ..."
	@until curl -s -o /dev/null -w "%{http_code}" $(LOCAL_URL)/wp-admin/install.php | grep -Eq "200"; do \
		echo "⏳ En attente..."; \
		sleep 2; \
	done;
	@echo "✅ Services ok ..."

# ⚙️  Installation WordPress (relit le .env : le conteneur est recréé si une valeur a changé)
install: doctor
	@test -n "$(WORDPRESS_ADMIN_USER)" || { \
		echo "❌ WORDPRESS_ADMIN_USER est vide dans .env : une migration a remplacé les comptes du site."; \
		echo "   Connecte-toi avec ceux de la base importée. Pour repartir d'une install neuve : make setup"; \
		exit 1; }
	@docker compose up -d --no-build
	@echo "\n⭐ Installation de wordpress..."
	@$(DC_SH) 'wp core install --url="$$1" --title="$$WP_TITLE" --admin_user="$$WP_ADMIN_USER" \
		--admin_password="$$WP_ADMIN_PASSWORD" --admin_email="$$WP_ADMIN_EMAIL" --locale="$$2" && \
		wp user update "$$WP_ADMIN_USER" --user_pass="$$WP_ADMIN_PASSWORD" --skip-email' \
		sh '$(LOCAL_URL)' '$(WORDPRESS_LOCALE)'

	@$(DC_WP) rewrite structure '$(WORDPRESS_WEBSITE_POST_URL_STRUCTURE)'

	@echo "\n🌐 Passage de WordPress en français..."
	@$(DC_WP) language core install $(WORDPRESS_LOCALE)
	@$(DC_WP) site switch-language $(WORDPRESS_LOCALE)

	@echo "\n🧹 Suppression des plugins par défaut de WordPress..."
	@$(DC_WP) plugin delete $(WORDPRESS_DEFAULT_PLUGINS)

	@echo "\n🎨 Installation du thème et des plugins (plugins.md)..."
	@ok=""; ko=""; inactif=""; first=1; \
	for t in $(WP_THEME); do \
		if $(DC_WP) theme install $$t; then \
			ok="$$ok $$t"; \
			if [ $$first = 1 ]; then $(DC_WP) theme activate $$t && first=0; fi; \
		else echo "⚠️  $$t introuvable sur wordpress.org"; ko="$$ko $$t"; fi; \
	done; \
	for p in $(WP_PLUGINS); do \
		if ! $(DC_WP) plugin install $$p; then echo "⚠️  $$p introuvable sur wordpress.org"; ko="$$ko $$p"; \
		elif $(DC_WP) plugin activate $$p; then ok="$$ok $$p"; \
		else echo "⚠️  $$p installé mais pas activé"; inactif="$$inactif $$p"; fi; \
	done; \
	echo "\n🧹 Suppression des thèmes twentytwenty* inactifs..."; \
	$(DC_SH) 'wp theme list --status=inactive --field=name | grep "^twentytwenty" | xargs -r wp theme delete'; \
	echo "\n🌐 Traductions du thème et des plugins..."; \
	$(DC_WP) language theme install --all $(WORDPRESS_LOCALE) >/dev/null; \
	$(DC_WP) language plugin install --all $(WORDPRESS_LOCALE) >/dev/null; \
	echo "\n📋 Récapitulatif"; \
	echo "   ✅ installés et activés :$${ok:- aucun}"; \
	echo "   ⚠️  introuvables :$${ko:- aucun}"; \
	if [ -n "$$inactif" ]; then echo "   ⚠️  non activés :$$inactif"; fi

	@echo "\n🧹 Suppression des articles et pages par défaut de WordPress..."
	@$(DC_SH) 'ids=""; for id in $$1; do wp post get "$$id" --field=ID > /dev/null 2>&1 && ids="$$ids $$id"; done; \
		[ -n "$$ids" ] && wp post delete --force $$ids || echo "   déjà supprimés"' \
		sh '$(WORDPRESS_DEFAULT_POSTS_PAGES)'

	@echo "\n⭐ Installation de WordPress terminée : $(LOCAL_URL)/wp-admin \n"


# ⚙️  Accès au container wordpress
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
	@sudo find db_data -mindepth 1 ! -name .keep -delete && sudo chown $$(id -u):$$(id -g) db_data

# ♻️  Nettoyage complet (down + suppression)
reset: clean
	@echo "\n♻️  Réinitialisation complète terminée. \n"

# 📋 Liste commentée des commandes
help:
	@awk '/^# /{c=substr($$0,3);next} /^[a-z][a-z-]*:/{split($$0,t,":"); if(c!="")printf "  %-22s %s\n",t[1],c} {c=""}' Makefile


# ═══ Synchro ════════════════════════════════════════════════════════════════════
# Moteur : scripts/wp-sync.sh ; ici, seulement la composition des valeurs du .env (spec 002).
# Questions au lancement (réponses lisibles sur l'entrée standard) ; WHAT=db|files|all saute la première.
.PHONY: pull-staging pull-prod push-staging push-prod copy-prod-to-staging copy-staging-to-prod \
	deploy-theme-staging deploy-theme-prod restore backups-clean backups-purge check-urls ssh-alias

SYNC = LOCAL_URL='$(LOCAL_URL)' \
	STAGING_SSH='$(STAGING_SSH)' STAGING_PATH='$(STAGING_PATH)' STAGING_URL='$(STAGING_URL)' \
	PROD_SSH='$(PROD_SSH)' PROD_PATH='$(PROD_PATH)' PROD_URL='$(PROD_URL)' \
	THEME_SLUG='$(THEME_SLUG)' SYNC_EXCLUDES='$(SYNC_EXCLUDES)' WHAT='$(WHAT)' \
	BACKUP_KEEP='$(BACKUP_KEEP)' WP_CMD='$(WP_CMD)' \
	bash scripts/wp-sync.sh

# 📥 Staging vers local (base et/ou fichiers)
pull-staging:
	@$(SYNC) run staging local

# 📥 Prod vers local (base et/ou fichiers)
pull-prod:
	@$(SYNC) run prod local

# 📤 Local vers staging (base et/ou fichiers)
push-staging:
	@$(SYNC) run local staging

# 📤 Local vers prod (base et/ou fichiers, PROD à taper)
push-prod:
	@$(SYNC) run local prod

# 🔁 Prod vers staging, base locale intacte
copy-prod-to-staging:
	@$(SYNC) run prod staging

# 🔁 Staging vers prod, base locale intacte (PROD à taper)
copy-staging-to-prod:
	@$(SYNC) run staging prod

# 🚀 Build (script npm build) et envoi du thème enfant sur le staging
deploy-theme-staging:
	@$(SYNC) theme staging

# 🚀 Build (script npm build) et envoi du thème enfant sur la prod
deploy-theme-prod:
	@$(SYNC) theme prod

# ⏪ Restaure un backup de db_backups/ (le plus récent par défaut)
restore:
	@$(SYNC) restore

# 🧹 Garde les 3 backups les plus récents par environnement (fait aussi après chaque synchro)
backups-clean:
	@$(SYNC) backups-clean

# 🗑️  Supprime TOUS les backups (base et fichiers) pour libérer la place
backups-purge:
	@$(SYNC) backups-purge

# 🔍 URL de staging/prod restées dans la base locale après une synchro
check-urls:
	@$(SYNC) check-urls $(ENV)

# 🔑 Crée les alias SSH du projet (prod et staging) et remplit le .env
ssh-alias:
	@bash scripts/ssh-alias.sh
