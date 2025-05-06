# wp-autoinstall
Wordpress Auto installation de Wordpress via Docker

## Description
Script permettant d'installer Wordpress en Français en locall

## Dependances
- Git
- Docker

## Process

1. Créer un dossier pour le projet
```bash
# Créer le dossier
mkdir <nom_du_dossier>
# Se placer a l'intérieur du dossier
cd <nom_du_dossier>
```
2. Git clone ce dépot
```bash
git clone https://github.com/romainarchimbaud/wp-autoinstall.git ./
# ou
git clone git@github.com:romainarchimbaud/wp-autoinstall.git ./
```
3. Supprimer le dossier .git
```bash
rm -rf .git
```
4. Initialiser le fichier `.env`
```bash
cp .env.example .env
```
5. Renseigner le fichier `.env`
    > **Note :**
    > Si le projet est destiné à récupérer une installation, ne renseignez que :
    > - `COMPOSE_PROJECT_NAME` : `nom_du_projet`
    > - `WORDPRESS_REPO_PLUGINS` : `updraftplus`

    - `COMPOSE_PROJECT_NAME` : nom_du_projet
    - `WORDPRESS_ADMIN_USER` : votre user
    - `WORDPRESS_ADMIN_PASSWORD` : votre password
    - `WORDPRESS_ADMIN_EMAIL` : votre e-mail
    - `WORDPRESS_REPO_PLUGINS` : garder ce que vous souhaitez


6. Lancer l'installation
  ### Full process
```bash
make autoinstall
```
