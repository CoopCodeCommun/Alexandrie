#!/bin/bash
# =============================================================================
# bin/configurer_env.sh — Fabrique le .env d'une machine neuve
# / bin/configurer_env.sh — Builds a fresh machine's .env
#
# S'EXECUTE DEPUIS L'HOTE, AVANT `docker compose up`. Appele par
# `make install`, en premier.
#
# POURQUOI CE SCRIPT EXISTE
#
# `docker compose` LIT le .env : sans lui, MYSQL_PASSWORD est vide et la
# base refuse de s'initialiser. L'installation commencait donc par une
# etape non ecrite — « copier .env.example et le remplir » — dont seul le
# README portait la trace. Son oubli le plus courant ne casse rien tout de
# suite : il laisse la cle JWT d'exemple en production, et personne ne le
# voit. / compose READS the .env; the install began with an unwritten step.
#
# QUATRE QUESTIONS, PAS DIX — ET DEUX SE SAUTENT D'UNE TOUCHE
#
#   1. dev ou prod ?   (regle le certificat et la verification TLS du CDN)
#   2. le domaine ?    (les trois URLs en decoulent)
#   3. le serveur de sauvegarde ? (facultatif : `make backup` le redemande)
#   4. un serveur de courriel ?   (facultatif : sert au seul « mot de
#                                  passe oublie »)
#
# Les deux dernieres se repondent par Entree. On les pose ICI, une bonne
# fois, plutot que de les laisser surgir un mois plus tard au milieu d'une
# manoeuvre — et surtout plutot que de les coder en dur dans un script
# versionne : l'adresse d'un serveur de sauvegarde designe VOTRE
# infrastructure, elle n'a rien a faire sur une forge publique.
# / The last two are Enter-to-skip. Asked here once, rather than surfacing
# a month later mid-operation — and rather than being hard-coded in a
# versioned script, which would publish your infrastructure.
#
# Les SECRETS NE SONT JAMAIS DEMANDES : cle JWT, mots de passe MySQL et
# cles S3 sont tires au hasard. Une cle saisie a la main est une cle
# faible, ou recopiee d'un autre projet. Le mot de passe SMTP fait
# exception — il n'est pas a nous, on ne peut que le recevoir.
#
# UNE SEULE QUESTION POUR QUATRE VARIABLES COUPLEES
#
# DOMAIN, FRONTEND_URL, API_URL et CDN_URL doivent bouger ENSEMBLE. Les
# demander separement, c'est offrir quatre facons de se tromper, dont deux
# ne se voient pas :
#   - COOKIE_DOMAIN (= DOMAIN) qui ne couvre pas l'API -> le login REUSSIT,
#     puis l'utilisateur est deconnecte a la page suivante, sans message.
#   - CDN_URL portant un chemin -> la signature S3 echoue et les fichiers
#     televerses deviennent inaccessibles.
# On pose donc UNE question et on ecrit les quatre lignes.
# / One question writes all four, because getting them out of step breaks
# the login and the file URLs, silently.
#
# IDEMPOTENT : si un .env existe, ce script ne fait RIEN. `make install`
# est rejoue a chaque demarrage ; regenerer le fichier y perdrait le mot de
# passe de la base — donc l'acces aux donnees — et la passphrase du depot
# de sauvegarde, ce qui rendrait toutes les archives illisibles.
# / Idempotent: regenerating would lose the database password and the
# backup passphrase.
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"

FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"
FICHIER_MODELE="$REPERTOIRE_DU_PROJET/.env.example"

dire() { echo "[env] $*"; }

# DEFINIE ICI, ET PAS PLUS BAS AVEC LES AUTRES : elle est appelee dans la
# boucle de saisie du mot de passe SMTP, bien avant la section d'ecriture.
# Rangee avec `remplacer_la_ligne`, bash rendait « apostrophe_refusee :
# commande introuvable » — et comme la boucle attend qu'elle rende 0 pour
# sortir, l'installation tournait EN ROND, redemandant le mot de passe
# indefiniment. Une fonction shell n'existe qu'a partir de sa definition.
# / Defined here because it is called from the SMTP password loop, long
# before the writing section: filed with the others, the loop spun forever.
apostrophe_refusee() {  # apostrophe_refusee <valeur> -> 0 si la valeur passe
    case "$1" in
        *\'*) return 1 ;;
        *)    return 0 ;;
    esac
}

demander() {  # demander <invite> [defaut] -> reponse sur stdout
    local invite="$1" defaut="${2:-}" reponse=""
    if [ -n "$defaut" ]; then
        read -r -p "  $invite [$defaut] : " reponse || true
        echo "${reponse:-$defaut}"
    else
        read -r -p "  $invite : " reponse || true
        echo "$reponse"
    fi
}


#### RIEN A FAIRE SI LE FICHIER EXISTE ####
if [ -f "$FICHIER_ENV" ]; then
    dire ".env deja present — inchange."
    exit 0
fi

[ -f "$FICHIER_MODELE" ] || {
    echo "[env] .env.example introuvable : $FICHIER_MODELE" >&2
    exit 1
}
command -v openssl >/dev/null || {
    echo "[env] openssl introuvable : impossible de tirer les secrets." >&2
    exit 1
}


#### LES SECRETS, TIRES AU HASARD ####
# En hexadecimal : ce fichier est lu par docker compose, dont l'analyseur
# interprete `$`. Une valeur base64 en portant un donnerait une valeur
# differente cote conteneur et cote script — et le mot de passe de la base
# ne serait plus le meme des deux cotes. 32 octets hexadecimaux, c'est
# 256 bits d'entropie. / Hex, because compose interprets `$`.
CLE_JWT="$(openssl rand -hex 32)"
MOT_DE_PASSE_MYSQL="$(openssl rand -hex 24)"
MOT_DE_PASSE_ROOT_MYSQL="$(openssl rand -hex 24)"
CLE_S3="$(openssl rand -hex 12)"
SECRET_S3="$(openssl rand -hex 24)"


#### LES QUESTIONS ####
MODE="prod"
DOMAINE="alexandrie.example.fr"
# Vides = « on garde ce que porte le fichier d'exemple ». Voir plus bas :
# on ne remplace une ligne que si la reponse n'est pas vide.
# / Empty = keep whatever the example file carries.
URL_SAUVEGARDE=""
PORT_SAUVEGARDE=""
SMTP_HOTE=""; SMTP_ADRESSE=""; SMTP_MOTDEPASSE=""

if [ -t 0 ]; then
    echo
    dire "Aucun .env : je le fabrique. Quatre questions, dont deux facultatives."
    echo

    echo "  Cette machine est :"
    echo "    1) un poste de developpement  (domaine .localhost, certificat auto-signe)"
    echo "    2) une machine de production  (certificat Let's Encrypt via Traefik)"
    case "$(demander "Ton choix" "1")" in
        2) MODE="prod" ;;
        *) MODE="dev"  ;;
    esac

    echo
    echo "  Le domaine du SITE. L'API et le CDN prendront 'api.' et 'cdn.'"
    echo "  devant, et le cookie de session portera le domaine du site :"
    echo "  c'est le seul reglage qui fait tenir la connexion."
    if [ "$MODE" = "dev" ]; then
        DOMAINE="$(demander "Domaine" "alexandrie.localhost")"
    else
        DOMAINE="$(demander "Domaine (ex. alexandrie.exemple.fr)" "")"
        while [ -z "$DOMAINE" ]; do
            echo "  Un domaine est necessaire : traefik route par hote."
            DOMAINE="$(demander "Domaine" "")"
        done
    fi

    echo
    echo "  Le serveur de sauvegarde (borgwarehouse), si tu en as un."
    echo "  Facultatif : \`make backup\` le redemandera le moment venu."
    URL_SAUVEGARDE="$(demander "URL de borgwarehouse (Entree pour passer)" "")"
    if [ -n "$URL_SAUVEGARDE" ]; then
        PORT_SAUVEGARDE="$(demander "Port SSH de borgwarehouse" "2226")"
    fi

    echo
    echo "  Un serveur de courriel, enfin. Il ne sert QU'A une chose : le"
    echo "  lien « mot de passe oublie ». Sans lui, tout le reste marche."
    echo "  Attention : le backend impose le SSL implicite, donc le PORT 465."
    echo "  Un serveur qui n'ecoute qu'en STARTTLS sur 587 ne conviendra pas."
    SMTP_HOTE="$(demander "Hote SMTP (Entree pour passer)" "")"
    if [ -n "$SMTP_HOTE" ]; then
        # La meme adresse sert d'identifiant ET d'expediteur : ce n'est pas
        # deux reglages, c'est un seul. / One setting, not two.
        SMTP_ADRESSE="$(demander "Adresse d'envoi (sert aussi d'identifiant)" "")"
        # On redemande TOUT DE SUITE plutot que d'echouer a l'ecriture :
        # la saisie est masquee, l'utilisateur ne voit pas ce qu'il a tape,
        # et un abandon a ce stade lui ferait tout recommencer.
        # / Asked again on the spot: the input is masked, and failing at
        # write time would make him start over.
        while :; do
            read -r -s -p "  Mot de passe SMTP (saisie masquee) : " SMTP_MOTDEPASSE || true
            echo
            apostrophe_refusee "$SMTP_MOTDEPASSE" && break
            echo "  Ce mot de passe contient une apostrophe. docker compose et"
            echo "  bash ne savent pas la lire de la meme facon, et le fichier"
            echo "  produit empecherait la stack de demarrer. En choisir un autre,"
            echo "  ou laisser vide et renseigner SMTP_PASSWORD a la main ensuite."
        done
    fi
else
    # Sans terminal — `make install` appele depuis un script — on prend les
    # valeurs du fichier d'exemple plutot que d'attendre une reponse qui ne
    # viendra jamais. Le defaut est la PRODUCTION : accepter un certificat
    # auto-signe sur une machine qu'on croyait de prod ouvre la porte a un
    # intercepteur, l'inverse ne fait qu'afficher un avertissement dans le
    # navigateur. On se trompe du cote qui ne fuit pas.
    # / No terminal: production defaults, so a wrong guess does not accept
    # a forged certificate.
    dire "aucun terminal : je prends les valeurs par defaut (production)."
fi

# DEUX REGLAGES QUI DECOULENT DU MODE, ET UN SEUL LES ECRIT.
#
# CERT_RESOLVER vide en dev, et c'est important : un resolveur ACME
# demanderait a Let's Encrypt un certificat pour `alexandrie.localhost`,
# que Let's Encrypt REFUSE — `.localhost` n'est pas un domaine public. La
# demande echoue, Traefik la rejoue, et les journaux se remplissent d'une
# erreur qui n'a aucun rapport avec ce qu'on est en train de faire. Vide,
# Traefik sert son certificat auto-signe : le navigateur avertit une fois,
# et tout marche.
#
# MINIO_INSECURE_TLS suit : le client S3 signeur du backend joint le CDN
# par son nom public et refuserait ce certificat auto-signe.
# / An ACME resolver would ask Let's Encrypt for a `.localhost`
# certificate, which it refuses: the request fails, Traefik replays it,
# and the logs fill with an unrelated error. Empty, Traefik serves its
# self-signed certificate.
if [ "$MODE" = "dev" ]; then
    RESOLVEUR=""
    TLS_S3_PERMISSIF="true"
else
    RESOLVEUR="myresolver"
    TLS_S3_PERMISSIF="false"
fi


#### ECRITURE ####
# On part du fichier d'exemple et on ne remplace que les lignes concernees :
# sa forme — l'ordre, les commentaires, les variables facultatives — reste
# sa seule definition. La reecrire ici en ferait une deuxieme, et les deux
# divergeraient. / We start from the example file and only replace the
# relevant lines: its shape stays defined in one place.
cp "$FICHIER_MODELE" "$FICHIER_ENV"

# TOUTE VALEUR EST ECRITE ENTRE GUILLEMETS SIMPLES, sans exception.
#
# Ce fichier est lu par DEUX analyseurs qui ne se ressemblent pas : docker
# compose, et le `.` de bash dans les scripts de sauvegarde. Une valeur nue
# les fait diverger, ou les casse — mesures du 17 aout 2026, avec le mot de
# passe `abc$def|ghi&jkl mno` :
#
#   nu          compose transmet  abc|ghi&jkl mno   ($def avale EN SILENCE)
#               bash              « ghi : commande introuvable », valeur vide
#   entre ' '   compose transmet  abc$def|ghi&jkl mno
#               bash              abc$def|ghi&jkl mno
#
# Les deux tombent juste, et seulement ainsi. Sans cela, un mot de passe
# SMTP portant un `$` — cas banal — arriverait ampute cote conteneur, et
# tuerait la sauvegarde cote script : `set -e` sur une ligne du .env que
# bash tente d'executer. La panne serait totale et muette.
#
# UNE APOSTROPHE DANS LA VALEUR EST REFUSEE, faute d'encodage commun.
# L'echappement `'\''` — celui de bash — a bien ete essaye : compose n'en
# veut pas, et pas a moitie. Mesure du 17 aout 2026 :
#
#   .env : MOTDEPASSE='il l'\''a dit'
#   -> failed to read .env: line 1: unexpected character "\" in variable
#      name — et TOUTE la stack refuse de demarrer.
#
# L'analyseur de compose ne connait pas d'echappement a l'interieur des
# guillemets simples, et les guillemets DOUBLES rouvriraient
# l'interpolation de `$`. Il n'existe donc aucune ecriture qui convienne
# aux deux. Plutot que de produire un fichier qui casse la stack entiere
# pour un caractere, on refuse a la saisie, en disant pourquoi.
#
# `\`, `&` et `|` sont echappes pour sed, dont `&` signifie « tout le
# motif » dans un remplacement.
# / An apostrophe is refused for lack of a shared encoding: bash's `'\''`
# makes compose reject the whole file, and double quotes would reopen `$`
# interpolation. Better to refuse one character than to break the stack.
remplacer_la_ligne() {  # remplacer_la_ligne <VARIABLE> <valeur>
    local variable="$1" valeur="$2" echappee
    apostrophe_refusee "$valeur" || {
        echo "[env] valeur de $variable refusee : elle contient une apostrophe," >&2
        echo "      que docker compose et bash ne savent pas lire de la meme" >&2
        echo "      facon. Choisir une valeur sans apostrophe." >&2
        exit 1
    }
    echappee="$(printf "%s" "'$valeur'" | sed 's/[\\&|]/\\&/g')"
    sed -i "s|^${variable}=.*|${variable}=${echappee}|" "$FICHIER_ENV"
}

remplacer_la_ligne DOMAIN       "$DOMAINE"
remplacer_la_ligne FRONTEND_URL "https://$DOMAINE"
remplacer_la_ligne API_URL      "https://api.$DOMAINE"
remplacer_la_ligne CDN_URL      "https://cdn.$DOMAINE"

remplacer_la_ligne CERT_RESOLVER      "$RESOLVEUR"
remplacer_la_ligne MINIO_INSECURE_TLS "$TLS_S3_PERMISSIF"

# CES QUATRE-LA NE S'ECRIVENT QUE SI ON A REPONDU. Une reponse vide doit
# LAISSER la ligne du fichier d'exemple, pas la vider : `SMTP_HOST=` vide
# est un reglage valide (« pas de courriel »), mais l'ecrire effacerait
# une valeur que quelqu'un aurait pu mettre dans .env.example pour son
# organisation. On ne touche qu'a ce qu'on a demande.
# / An empty answer must LEAVE the example file's line, not blank it.
[ -z "$URL_SAUVEGARDE" ]  || remplacer_la_ligne BORGWAREHOUSE_URL      "$URL_SAUVEGARDE"
[ -z "$PORT_SAUVEGARDE" ] || remplacer_la_ligne BORGWAREHOUSE_SSH_PORT "$PORT_SAUVEGARDE"
[ -z "$SMTP_HOTE" ]       || remplacer_la_ligne SMTP_HOST              "$SMTP_HOTE"
[ -z "$SMTP_ADRESSE" ]    || remplacer_la_ligne SMTP_MAIL              "$SMTP_ADRESSE"
[ -z "$SMTP_MOTDEPASSE" ] || remplacer_la_ligne SMTP_PASSWORD          "$SMTP_MOTDEPASSE"

remplacer_la_ligne JWT_SECRET          "$CLE_JWT"
remplacer_la_ligne MYSQL_PASSWORD      "$MOT_DE_PASSE_MYSQL"
remplacer_la_ligne MYSQL_ROOT_PASSWORD "$MOT_DE_PASSE_ROOT_MYSQL"
remplacer_la_ligne RUSTFS_ACCESS_KEY   "$CLE_S3"
remplacer_la_ligne RUSTFS_SECRET_KEY   "$SECRET_S3"

# Le fichier porte des secrets : il ne se lit que par son proprietaire.
# / The file holds secrets: owner-only.
chmod 600 "$FICHIER_ENV"


#### CE QU'ON VIENT D'ECRIRE ####
echo
dire "$FICHIER_ENV cree."
dire "  mode      : $MODE"
dire "  site      : https://$DOMAINE"
dire "  API       : https://api.$DOMAINE"
dire "  CDN       : https://cdn.$DOMAINE"
dire "  cookie    : $DOMAINE   (le domaine commun aux trois)"
if [ -n "$RESOLVEUR" ]; then
    dire "  certificat: Let's Encrypt, via le resolveur '$RESOLVEUR' de Traefik"
else
    dire "  certificat: aucun resolveur — Traefik servira son certificat"
    dire "              auto-signe. Le navigateur avertira une fois."
fi
dire "  secrets   : cle JWT, mots de passe MySQL et cles S3 tires au hasard"
echo
dire "Les trois noms doivent pointer sur cette machine. En production :"
dire "  trois enregistrements A, ou un joker *.$DOMAINE"
echo
dire "Ce fichier n'est PAS dans git, et rien ne le regenere : c'est la"
dire "seule copie du mot de passe de la base. Sur une machine de"
dire "production, le mettre au coffre."
echo
