# wp-autoinstall

Un WordPress en français, prêt à travailler, en moins de deux minutes. Et la synchro local ↔ staging ↔ prod qui va avec.

```bash
mkdir mon-projet && cd mon-projet
git clone https://github.com/romainarchimbaud/wp-autoinstall.git ./
rm -rf .git
make autoinstall
```

Un questionnaire, puis ça tourne seul : WordPress en français, vos thèmes et plugins installés et traduits, contenus et extensions par défaut retirés, permaliens réglés, port libre choisi tout seul. Pas de `.env` à éditer.

**Requis :** Git, Docker, whiptail.

## Le questionnaire

Titre du site, identifiant et e-mail admin, mot de passe (généré ou le vôtre, tous les caractères passent), thème et plugins à cocher, npm, URL de staging et de prod.

**Retour** pour corriger, **Échap** pour tout annuler. Un récapitulatif avant de lancer.

Relancer les questions plus tard : `make setup`. Sans terminal (script, agent) : aucune question, les valeurs viennent des variables d'environnement, sinon du `.env`.

```bash
WORDPRESS_ADMIN_EMAIL=moi@example.com make autoinstall < /dev/null
```

## Thème et plugins : `plugins.md`

Une ligne par élément. Coché = pré-coché dans le questionnaire.

```markdown
## Thème
- [x] `generatepress` GeneratePress

## Plugins
- [ ] `cookie-notice` Cookie Notice
```

Le slug est celui de `wordpress.org/plugins/<slug>`. Versions gratuites uniquement. Un slug introuvable est signalé sans bloquer les autres.

## Les ports

Rien à choisir : le premier port libre à partir de 8080 pour le site, le suivant pour phpMyAdmin. Écrits une fois dans `.env` puis gardés, et réservés même projet arrêté. Plusieurs projets tournent en parallèle sans conflit.

`make doctor` vérifie avant chaque démarrage et nomme le projet fautif si un port a été pris.

## npm

Pas installé par défaut, ça économise deux minutes de build. Cochez `npm` dans le questionnaire pour l'avoir, plus `vite` et/ou `node` si vous voulez leur port publié. Sur un projet existant, `make build` après changement.

## Synchro local ↔ staging ↔ prod

Base et fichiers, dans tous les sens, y compris prod → staging sans toucher au local.

```text
make pull-staging | pull-prod                      distant → local
make push-staging | push-prod                      local → distant
make copy-prod-to-staging | copy-staging-to-prod   distant → distant
make deploy-theme-staging | deploy-theme-prod      build npm + envoi du thème enfant
make restore                                       restaure un point de retour
make check-urls                                    URL distantes restées en base
make ssh-alias                                     crée les alias SSH du projet
```

Chaque commande demande quoi copier, puis une confirmation à taper (`yes`, ou `PROD` pour la production). `WHAT=db`, `WHAT=files` ou `WHAT=all` saute la première question.

**Requis côté serveur :** WP-CLI et `rsync`. Les commandes le vérifient avant tout transfert.

### Configurer les accès

`make ssh-alias` demande les accès, écrit les alias SSH, remplit le `.env` et teste tout (connexion, WP-CLI, présence du WordPress).

```dotenv
STAGING_SSH=monprojet-staging
PROD_SSH=monprojet-prod
STAGING_PATH=staging
PROD_PATH=public_html
STAGING_URL=https://staging.monsite.fr
PROD_URL=https://www.monsite.fr
THEME_SLUG=mon-theme
SYNC_EXCLUDES=uploads/2012 uploads/2013
```

Chemins relatifs au dossier de connexion SSH. `THEME_SLUG` : le thème enfant, jamais copié par les synchros (il vient de git). `SYNC_EXCLUDES` : dossiers de `wp-content` à ne jamais transférer.

### Points de retour

Avant chaque import, un backup daté est créé automatiquement : en local dans `db_backups/`, et sur le serveur lui-même avant d'écraser des fichiers distants. Par liens durs, donc instantané et quasi gratuit en disque.

`make restore` remet base et fichiers ensemble. `make backups-clean` applique la rétention, `make backups-purge` efface tout, local et serveurs compris.

## Licence

MIT.
