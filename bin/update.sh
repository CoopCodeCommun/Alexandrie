#!/bin/bash
# =============================================================================
# bin/update.sh — Met a jour Alexandrie, et VERIFIE que ca tient
# / bin/update.sh — Updates Alexandrie, and CHECKS that it holds
#
# S'EXECUTE DEPUIS L'HOTE.   Lance par :  make update
#
# `docker compose pull && docker compose up -d` tient en une ligne. Ce
# script existe pour les trois choses que cette ligne ne fait pas.
#
# 1. IL EXIGE UN FILET. Une mise a jour qui casse la base est irreversible
#    sans sauvegarde recente : les migrations d'Alexandrie ne savent pas
#    revenir en arriere. On verifie donc qu'une archive fraiche existe
#    AVANT de tirer quoi que ce soit.
#
# 2. IL NOTE OU L'ON ETAIT. `latest` ne dit pas quelle version tourne. Une
#    fois l'image remplacee, plus rien sur la machine ne dit d'ou l'on
#    vient — sauf si on l'a ecrit avant. Ce script affiche les empreintes
#    (digests) d'avant : elles s'epinglent telles quelles dans le .env
#    pour revenir en arriere.
#
# 3. IL VERIFIE APRES. Un conteneur `running` ne prouve rien : le backend
#    peut tourner sur une migration a moitie passee. Les controles
#    portent donc sur ce qui se voit — l'etat des migrations, le nombre de
#    lignes, et les trois URLs.
#
# / The one-liner does none of these: require a fresh backup, record where
# we came from, and check afterwards that the thing actually works.
#
# USAGE
#   make update                 (demande confirmation, exige une sauvegarde)
#   make update CONFIRME=oui    (sans question)
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"
FICHIER_COMPOSE="$REPERTOIRE_DU_PROJET/docker-compose.yml"

SERVICES="mysql rustfs backend frontend"

# `nodes` porte TOUT le contenu : documents, dossiers et fichiers
# televerses ne sont qu'un champ `role` de cette table. `sessions` est
# ecartee : le backend en supprime les entrees perimees a chaque
# demarrage, donc a chaque mise a jour.
# / `nodes` holds everything; `sessions` is pruned at every startup.
TABLES_COMPAREES="users nodes permissions user_settings"

NOMBRE_D_ERREURS=0
dire()  { echo "[maj] $*"; }
ok()    { echo "  [ok]   $*"; }
ko()    { echo "  [KO]   $*" >&2; NOMBRE_D_ERREURS=$((NOMBRE_D_ERREURS + 1)); }
fatal() { echo "[maj] ERREUR : $*" >&2; exit 2; }

[ -f "$FICHIER_ENV" ] || fatal ".env introuvable. Commencer par :  make install"
[ -f "$FICHIER_COMPOSE" ] || fatal "docker-compose.yml introuvable : $FICHIER_COMPOSE"
set -a
# shellcheck disable=SC1090
. <(grep -vE '^[[:space:]]*(UID|GID)=' "$FICHIER_ENV")
set +a

: "${DOMAIN:?DOMAIN absent du .env}"
for outil in docker curl; do
    command -v "$outil" >/dev/null || fatal "$outil introuvable dans le PATH."
done


#### OUTILLAGE ####
# La requete est passee en ARGUMENT au shell du conteneur, pas collee
# dans son texte. Collee, une requete portant un guillemet double —
# `concat(version, "/", dirty)` — refermait le `-e "` a sa place : mysql
# recevait une requete tronquee, rendait une chaine vide, et l'etat des
# migrations s'affichait « inconnue » sur une base parfaitement lisible
# (mesure du 16 aout 2026). En argument, le shell developpe la variable
# sans relire les guillemets qu'elle contient.
# / Passed as an ARGUMENT, not pasted into the script's text: a query
# holding a double quote closed the `-e "` early, and mysql answered an
# empty string on a perfectly readable database.
dans_mysql() {
    docker compose -f "$FICHIER_COMPOSE" exec -T mysql \
        sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -B -u"$MYSQL_USER" \
            -e "$1" "$MYSQL_DATABASE"' _ "$1" 2>/dev/null | tr -d '[:space:]'
}

# L'empreinte epinglable de l'image que fait tourner un conteneur. On
# passe par l'ID de l'image, pas par son tag : apres un `pull`, le tag
# `latest` designe la NOUVELLE image, et interroger le tag rendrait la
# nouvelle empreinte des deux cotes de la comparaison.
# / Via the image ID, not the tag: after a pull, `latest` points at the
# new image and the tag would answer the same digest on both sides.
empreinte_en_service() {  # empreinte_en_service <conteneur>
    local id
    id="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null || true)"
    [ -n "$id" ] || { echo "absent"; return 0; }
    docker inspect --format \
        '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' \
        "$id" 2>/dev/null || echo "$id"
}

# LES IMAGES DE L'AMONT NE PORTENT AUCUNE ETIQUETTE. Ce script a d'abord
# affiche `org.opencontainers.image.version` ; verifie le 16 aout 2026,
# `docker inspect ghcr.io/smaug6739/alexandrie-backend:latest` rend
# `Config.Labels = null` — pas une version manquante, aucune etiquette du
# tout. La colonne affichait donc « ? » partout, ce qui donne l'air d'une
# panne la ou il n'y a rien a lire.
#
# On affiche l'EMPREINTE abregee : c'est ce qui identifie vraiment une
# image, c'est ce qui s'epingle pour revenir en arriere, et c'est ce que
# `latest` cache.
# / Upstream's images carry no labels at all: Config.Labels is null. The
# digest is what actually identifies an image, and what `latest` hides.
empreinte_courte() {  # empreinte_courte <conteneur>
    local empreinte="$1"
    case "$empreinte" in
        *@sha256:*) echo "${empreinte##*@sha256:}" | cut -c1-12 ;;
        sha256:*)   echo "${empreinte#sha256:}" | cut -c1-12 ;;
        *)          echo "$empreinte" ;;
    esac
}

compter_les_lignes() {
    local resultat="" table nombre
    for table in $TABLES_COMPAREES; do
        nombre="$(dans_mysql "select count(*) from $table" || true)"
        case "$nombre" in ''|*[!0-9]*) nombre="?" ;; esac
        resultat="$resultat $table=$nombre"
    done
    echo "${resultat# }"
}

verifier_http() {  # verifier_http <libelle> <url> <motif de codes acceptes>
    bash "$REPERTOIRE_DU_SCRIPT/verifier_http.sh" "$@" \
        || NOMBRE_D_ERREURS=$((NOMBRE_D_ERREURS + 1))
}


#### 1. LE FILET ####
echo
dire "1/5 — y a-t-il une sauvegarde fraiche ?"
if [ -z "${BORG_REPO:-}" ]; then
    echo "  [!]    aucune sauvegarde configuree sur cette machine."
    echo "         Les migrations d'Alexandrie ne savent pas revenir en"
    echo "         arriere : sans archive, une mise a jour ratee est"
    echo "         definitive. La configurer prend deux minutes :  make backup"
    if [ "${CONFIRME:-}" != "oui" ]; then
        [ -t 0 ] || fatal "sans sauvegarde et sans terminal. Forcer : make update CONFIRME=oui"
        read -r -p "  Continuer SANS filet ? Taper SANSFILET : " REPONSE
        [ "$REPONSE" = "SANSFILET" ] || { echo "[maj] annule."; exit 1; }
    fi
elif bash "$REPERTOIRE_DU_SCRIPT/verifier_archive.sh"; then
    ok "la sauvegarde en place est restaurable."
    # ON EN PREND UNE FRAICHE, ET CE N'EST PAS DU LUXE. Ce script se
    # contentait de VERIFIER la derniere archive — qui peut dater de
    # AGE_MAX_HEURES, soit 25 h en quotidien — et son message d'echec
    # invitait pourtant a « restaurer la sauvegarde prise au debut de
    # cette mise a jour ». Aucune ne l'etait. Qui suivait ce conseil
    # apres une migration ratee ecrasait une JOURNEE d'ecritures avec
    # l'archive de la veille, sur la foi du script.
    #
    # Borg deduplique : une archive prise juste apres une autre ne coute
    # que ce qui a change. Le filet devient donc reel, et le message de
    # retour arriere dit enfin la verite.
    # / The script only CHECKED the last archive — up to 25 h old — while
    # its failure message invited restoring "the backup taken at the
    # start of this update". None was. Following that advice after a
    # failed migration overwrote a full day of edits.
    dire "sauvegarde de l'etat actuel, avant de toucher a quoi que ce soit..."
    bash "$REPERTOIRE_DU_SCRIPT/backup.sh" || fatal "la sauvegarde a echoue — mise a jour annulee.
                 Mettre a jour sans filet n'est pas une option : les
                 migrations d'Alexandrie ne redescendent pas."
    ok "filet en place : l'etat d'avant la mise a jour est archive."
else
    echo >&2
    if [ "${CONFIRME:-}" = "oui" ]; then
        echo "  [!]    sauvegarde non fiable, mais CONFIRME=oui : on continue." >&2
    else
        fatal "la derniere sauvegarde n'est pas fiable — mise a jour refusee.
                 Corriger d'abord :  make backup
                 Passer outre :      make update CONFIRME=oui"
    fi
fi


#### 2. D'OU L'ON PART ####
echo
dire "2/5 — etat actuel"

docker compose -f "$FICHIER_COMPOSE" exec -T mysql true >/dev/null 2>&1 \
    || fatal "la stack ne tourne pas. La demarrer (make install), puis relancer."

LIGNES_AVANT="$(compter_les_lignes)"
MIGRATION_AVANT="$(dans_mysql 'select concat(version, "/", dirty) from schema_migrations limit 1' || true)"
echo "  base       : $LIGNES_AVANT"
echo "  migration  : ${MIGRATION_AVANT:-inconnue}   (version/dirty)"
echo
echo "  Empreintes EN SERVICE — c'est par elles qu'on revient en arriere :"
EMPREINTES_AVANT=""
for service in $SERVICES; do
    empreinte="$(empreinte_en_service "alexandrie_$service")"
    EMPREINTES_AVANT="$EMPREINTES_AVANT$service $empreinte"$'\n'
    printf '    %-9s %s\n' "$service" "$empreinte"
done


#### 3. LE PULL ####
echo
dire "3/5 — recuperation des images"
docker compose -f "$FICHIER_COMPOSE" pull

# Y a-t-il vraiment du neuf ? Le tag pointe maintenant sur l'image tiree ;
# on la compare a l'empreinte relevee AVANT le pull.
#
# La reference du tag est LUE SUR LE CONTENEUR (`.Config.Image`), pas
# recopiee ici. Ecrire `ghcr.io/smaug6739/alexandrie-backend:latest` dans
# ce script en ferait une deuxieme definition de ce que le compose dit
# deja — et le jour ou l'amont change de registre, la comparaison
# porterait sur une image que plus personne ne fait tourner, en annoncant
# « deja a jour ».
# / The tag reference is READ FROM THE CONTAINER, not copied here: a
# second definition would one day compare an image nobody runs.
CHANGEMENTS=""
CONTENEURS_ABSENTS=""
for service in $SERVICES; do
    avant="$(grep "^$service " <<< "$EMPREINTES_AVANT" | cut -d' ' -f2-)"
    reference="$(docker inspect --format '{{.Config.Image}}' "alexandrie_$service" 2>/dev/null || true)"
    # UN CONTENEUR ABSENT N'EST PAS « RIEN A FAIRE ». Cette ligne se
    # contentait d'un `continue` : avec les trois autres a jour, un
    # `alexandrie_frontend` supprime (plantage suivi d'un `docker rm`,
    # `up -d` interrompu) faisait conclure « la stack est deja a jour,
    # rien n'a ete redemarre » et sortir en 0 — sur une stack amputee
    # d'un service, sans que la branche appelle meme bin/attendre.sh.
    # / A missing container is not "nothing to do": the old `continue`
    # concluded "already up to date" on a stack short of one service.
    if [ -z "$reference" ]; then
        CONTENEURS_ABSENTS="$CONTENEURS_ABSENTS $service"
        continue
    fi
    apres="$(docker inspect --format \
        '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' \
        "$reference" 2>/dev/null || echo inconnue)"
    if [ "$avant" != "$apres" ]; then
        CHANGEMENTS="$CHANGEMENTS  $service : $apres"$'\n'
    fi
done

if [ -n "$CONTENEURS_ABSENTS" ]; then
    echo
    dire "conteneur(s) absent(s) :$CONTENEURS_ABSENTS"
    dire "La stack est incomplete — on ne peut pas conclure sur les versions."
    dire "La remonter d'abord :  make install"
    exit 1
fi

if [ -z "$CHANGEMENTS" ]; then
    echo
    dire "aucune image nouvelle : la stack est deja a jour."
    dire "Rien n'a ete redemarre."
    dire "(Changer ALEXANDRIE_TAG dans le .env ne se voit pas ici : c'est un"
    dire " changement de CIBLE, pas de contenu. L'appliquer avec make install.)"
    exit 0
fi

echo
dire "images nouvelles :"
printf '%s' "$CHANGEMENTS"

if [ "${CONFIRME:-}" != "oui" ]; then
    echo
    echo "  Le site sera injoignable une minute, le temps du redemarrage."
    [ -t 0 ] || fatal "entree non interactive. Pour lancer sans question : make update CONFIRME=oui"
    read -r -p "  Appliquer ? Taper oui : " REPONSE
    [ "$REPONSE" = "oui" ] || { echo "[maj] annule. Les images sont tirees, rien n'est applique."; exit 1; }
fi


#### 4. APPLICATION ####
echo
dire "4/5 — redemarrage sur les nouvelles images"
docker compose -f "$FICHIER_COMPOSE" up -d
bash "$REPERTOIRE_DU_SCRIPT/attendre.sh" 300


#### 5. PROCEDURE DE VERIFICATION ####
echo
dire "5/5 — verification"

# a) les migrations. `dirty = 1` veut dire qu'une migration s'est arretee
#    en plein milieu : le schema est dans un etat intermediaire, et le
#    backend refusera de repartir tant qu'on ne l'aura pas debloque a la
#    main. C'est le seul echec de mise a jour qui ne se voit pas dans les
#    codes HTTP — le site peut repondre 200 sur ses pages statiques.
#    / dirty = 1 means a migration stopped mid-way; the site can still
#    answer 200 on its static pages.
MIGRATION_APRES="$(dans_mysql 'select concat(version, "/", dirty) from schema_migrations limit 1' || true)"
case "$MIGRATION_APRES" in
    '')      ko "table schema_migrations illisible — la base repond-elle ?" ;;
    */1)     ko "MIGRATION INTERROMPUE (dirty=1) : $MIGRATION_APRES"
             ko "le schema est a moitie migre. Ne pas remettre en service." ;;
    */0)     if [ "$MIGRATION_APRES" = "$MIGRATION_AVANT" ]; then
                 ok "migrations : inchangees ($MIGRATION_APRES)"
             else
                 ok "migrations : ${MIGRATION_AVANT:-?} -> $MIGRATION_APRES"
             fi ;;
    *)       ko "etat de migration inattendu : $MIGRATION_APRES" ;;
esac

# b) les donnees. Une mise a jour peut ajouter des lignes, jamais en
#    perdre. / An update may add rows, never lose them.
LIGNES_APRES="$(compter_les_lignes)"
PERTE=""
for table in $TABLES_COMPAREES; do
    avant="$(grep -o "$table=[0-9?]*" <<< "$LIGNES_AVANT" | cut -d= -f2)"
    apres="$(grep -o "$table=[0-9?]*" <<< "$LIGNES_APRES" | cut -d= -f2)"
    case "$avant$apres" in *'?'*) PERTE="$PERTE $table(illisible)"; continue ;; esac
    [ "$apres" -lt "$avant" ] && PERTE="$PERTE $table($avant->$apres)"
done
if [ -z "$PERTE" ]; then
    ok "donnees : $LIGNES_APRES"
else
    ko "DES LIGNES ONT DISPARU :$PERTE"
    ko "  avant : $LIGNES_AVANT"
    ko "  apres : $LIGNES_APRES"
fi

# c) le site repond-il, a travers le proxy ? Chaque code attendu ne doit
#    pouvoir venir QUE du service vise — Traefik rend 404 quand aucun
#    routeur ne correspond, donc un motif qui accepte 404 declarerait au
#    vert un conteneur que la mise a jour vient de faire disparaitre.
#    401 ne sort que du middleware d'authentification de Gin, 403 que de
#    rustfs. Voir le commentaire detaille dans bin/check_backup.sh.
#    / Each expected code must be one only the target can produce.
verifier_http "site        https://$DOMAIN"     "https://$DOMAIN/" '^[23]'
verifier_http "API         https://api.$DOMAIN" "https://api.$DOMAIN/api/nodes/search" '^401$'
verifier_http "CDN         https://cdn.$DOMAIN" "https://cdn.$DOMAIN/${MINIO_BUCKET:-alexandrie}/" '^403$'


#### VERDICT ####
echo
if [ "$NOMBRE_D_ERREURS" -eq 0 ]; then
    dire "mise a jour reussie. Empreintes maintenant en service :"
    for service in $SERVICES; do
        printf '    %-9s %s\n' "$service" \
            "$(empreinte_courte "$(empreinte_en_service "alexandrie_$service")")"
    done
    echo
    dire "Prendre une sauvegarde de ce nouvel etat :  make backup"
    exit 0
fi

echo "[maj] $NOMBRE_D_ERREURS probleme(s) apres la mise a jour." >&2
echo >&2
echo "  REVENIR EN ARRIERE" >&2
echo >&2
echo "  1. Epingler la version precedente d'Alexandrie DANS LE .env :" >&2
echo >&2
echo "         ALEXANDRIE_TAG=v8.11.0     # le tag git de l'amont, avec son v" >&2
echo >&2
echo "     Les versions publiees sont les tags des releases de" >&2
echo "     github.com/Smaug6739/Alexandrie — ce sont elles qui nomment les" >&2
echo "     images. Puis :  make install" >&2
echo >&2
echo "     C'est le .env qu'on modifie, PAS docker-compose.yml : celui-ci" >&2
echo "     est suivi par git et serait ecrase au prochain git pull." >&2
echo >&2
echo "  2. Les empreintes qui tournaient avant cette mise a jour, pour" >&2
echo "     memoire — elles identifient l'image a coup sur, la ou un tag" >&2
echo "     peut etre republie :" >&2
echo >&2
printf '%s' "$EMPREINTES_AVANT" | sed 's/^/         /' >&2
echo >&2
echo "  3. Si la base a ete migree, revenir aux images d'avant NE SUFFIT" >&2
echo "     PAS : le schema, lui, ne redescend pas. Il faut alors restaurer" >&2
echo "     la sauvegarde prise au debut de cette mise a jour :" >&2
echo "         make restore" >&2
exit 1
