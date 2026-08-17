#!/bin/bash
# =============================================================================
# bin/verifier_dns.sh — Les trois noms resolvent-ils, AVANT de demarrer ?
# / bin/verifier_dns.sh — Do the three names resolve, BEFORE starting?
#
# S'EXECUTE DEPUIS L'HOTE. Appele par `make install`, JUSTE AVANT
# `docker compose up -d` — et l'ordre est tout l'interet du script.
#
# POURQUOI CE CONTROLE EXISTE : UN INCIDENT DU 17 AOUT 2026
#
# La stack a ete demarree sur un serveur ou seul le domaine principal
# avait son enregistrement DNS. Des que Traefik a vu les routeurs, il a
# demande a Let's Encrypt un certificat pour les trois noms. Deux
# validations ont echoue, encore et encore — et Let's Encrypt plafonne a
# CINQ ECHECS PAR NOM ET PAR HEURE :
#
#   429 :: urn:ietf:params:acme:error:rateLimited :: too many failed
#   authorizations (5) for "cdn.alexandrie..." in the last 1h0m0s
#
# Le DNS a ete corrige dans la minute. Mais le quota, lui, etait brule :
# une heure d'attente, sur un service qui aurait pu etre en ligne tout de
# suite. Et le symptome cote navigateur n'a RIEN a voir avec un
# certificat — c'est un « NetworkError when attempting to fetch
# resource » sur l'inscription, qui envoie chercher un probleme de CORS,
# de reseau, d'API. On perd l'heure d'attente, plus celle du diagnostic.
#
# Le cout est donc ASYMETRIQUE : verifier prend deux secondes, se tromper
# coute une heure. D'ou ce controle, et d'ou sa place — AVANT le premier
# `up`, parce qu'apres il est trop tard.
# / Measured incident: starting before DNS was ready burned Let's
# Encrypt's five-failures-per-hour quota. Checking costs two seconds,
# getting it wrong costs an hour — and the browser symptom looks nothing
# like a certificate problem.
#
# EN DEVELOPPEMENT, CE SCRIPT NE FAIT QUE S'ANNONCER. Sans resolveur ACME
# (`CERT_RESOLVER` vide), il n'y a pas de quota a bruler : `.localhost`
# resout tout seul et Traefik sert son certificat auto-signe.
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"
FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"

[ -f "$FICHIER_ENV" ] || { echo "[dns] .env introuvable : $FICHIER_ENV" >&2; exit 1; }

valeur_du_env() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$FICHIER_ENV" | tail -n1 | tr -d "'\""
}
DOMAINE="$(valeur_du_env DOMAIN)"
RESOLVEUR="$(valeur_du_env CERT_RESOLVER)"
[ -n "$DOMAINE" ] || { echo "[dns] DOMAIN absent du .env." >&2; exit 1; }

NOMS="$DOMAINE api.$DOMAINE cdn.$DOMAINE"

echo
echo "  ┌────────────────────────────────────────────────────────────────┐"
echo "  │  AVANT DE DEMARRER : les trois noms doivent pointer ici        │"
echo "  └────────────────────────────────────────────────────────────────┘"
echo
echo "    $DOMAINE          le site"
echo "    api.$DOMAINE      l'API"
echo "    cdn.$DOMAINE      les fichiers"
echo

#### POSTE DE DEVELOPPEMENT : RIEN A PERDRE ####
if [ -z "$RESOLVEUR" ]; then
    echo "  Aucun resolveur ACME (CERT_RESOLVER vide) : Traefik servira son"
    echo "  certificat auto-signe. En .localhost, les trois noms resolvent"
    echo "  tout seuls — rien a faire."
    echo
    echo "  Le navigateur avertira UNE FOIS PAR NOM. Accepter l'exception sur"
    echo "  les trois, api. et cdn. compris : sans cela, l'inscription echoue"
    echo "  sur un « NetworkError » qui ne parle pas de certificat."
    echo
    exit 0
fi

#### PRODUCTION : ON VERIFIE VRAIMENT ####
echo "  Resolveur ACME : $RESOLVEUR — Traefik va demander de vrais"
echo "  certificats des le demarrage. Verification des trois noms :"
echo

MANQUANTS=""
for nom in $NOMS; do
    # `getent ahostsv4` interroge le resolveur du systeme, celui-la meme
    # que docker et Traefik utiliseront. Un `dig @8.8.8.8` repondrait pour
    # un autre resolveur que le notre, et rassurerait a tort.
    # / getent asks the system resolver — the one Traefik will use.
    if ADRESSE="$(getent ahostsv4 "$nom" 2>/dev/null | awk 'NR==1{print $1}')" && [ -n "$ADRESSE" ]; then
        printf '    [ok]  %-40s %s\n' "$nom" "$ADRESSE"
    else
        printf '    [KO]  %-40s ne resout pas\n' "$nom"
        MANQUANTS="$MANQUANTS $nom"
    fi
done
echo

[ -z "$MANQUANTS" ] && {
    echo "  Les trois resolvent. Demarrage."
    echo
    exit 0
}

#### CE QUI SE PASSERA SI ON PASSE OUTRE ####
echo "  ┌────────────────────────────────────────────────────────────────┐"
echo "  │  ARRET : demarrer maintenant coutera UNE HEURE                 │"
echo "  └────────────────────────────────────────────────────────────────┘"
echo
echo "  Ces noms ne resolvent pas :$MANQUANTS"
echo
echo "  Des que les conteneurs demarrent, Traefik demande un certificat"
echo "  pour chacun. Let's Encrypt plafonne a CINQ echecs par nom et par"
echo "  heure : les tentatives se consommeront en quelques secondes, et"
echo "  le nom restera sans certificat pendant une heure — meme apres"
echo "  correction du DNS."
echo
echo "  Le symptome, lui, ne ressemblera pas a un probleme de certificat :"
echo "  l'inscription echouera sur « NetworkError when attempting to fetch"
echo "  resource », qui envoie chercher un souci de CORS ou de reseau."
echo
echo "  A FAIRE MAINTENANT"
echo "    - poser les enregistrements manquants (trois A, ou un joker"
echo "      *.$DOMAINE), et attendre leur propagation ;"
echo "    - verifier :  getent hosts api.$DOMAINE"
echo "    - puis relancer :  make install"
echo
echo "  Pour mettre au point sans rien consommer, viser le serveur de test"
echo "  de Let's Encrypt : decommenter \`caserver\` dans le traefik.yml du"
echo "  proxy. Les certificats ne sont pas reconnus, mais ils sont illimites."
echo

# On refuse, plutot que d'avertir et de continuer : un avertissement dans
# un flot de sortie ne s'arrete pas a temps, et le mal est fait au premier
# `up`. `CONFIRME=oui` reste la porte de sortie — un DNS interne, un
# /etc/hosts, une resolution que ce script ne sait pas voir.
# / We refuse rather than warn: a warning in a stream of output does not
# stop anyone in time, and the damage is done at the first `up`.
if [ "${CONFIRME:-}" = "oui" ]; then
    echo "  CONFIRME=oui : on demarre quand meme."
    echo
    exit 0
fi
echo "  Passer outre (DNS interne, /etc/hosts, resolution particuliere) :"
echo "    make install CONFIRME=oui"
echo
exit 1
