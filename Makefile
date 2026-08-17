# =============================================================================
# Makefile — Alexandrie auto-heberge
#
# POURQUOI CE FICHIER EXISTE
#
# La procedure d'installation d'une stack vit d'habitude dans un README :
# un document qu'on LIT, pas qu'on EXECUTE. Ce qui s'y trouve derive du
# jour ou quelqu'un tape une commande legerement differente, et personne
# ne le voit — jusqu'a la panne. Ici, ce qui se tape ne peut pas diverger
# de ce qui est ecrit, parce que c'est le meme texte.
# / An install procedure that lives in a README is a document you read,
# not one you run. Here, what you type cannot drift from what is written.
#
# TOUT SE LANCE DEPUIS L'HOTE. Aucune cible n'entre dans un conteneur pour
# y travailler : les images de l'amont sont minimales et n'ont pas de
# shell. Les scripts pilotent Docker de l'exterieur.
# / Everything runs from the host: the upstream images are minimal and
# have no shell.
#
# LE MAKEFILE N'ECRIT AUCUNE LOGIQUE. Toute la matiere est dans bin/ ; ce
# fichier ne fait qu'appeler. Deux definitions d'une meme sequence
# finissent toujours par diverger — et une sauvegarde qui derive ne le
# signale jamais.
# / No logic here: everything lives in bin/, this file only calls.
# =============================================================================

COMPOSE := docker compose

# Le reseau du reverse proxy. Il est `external:` dans le compose : c'est
# Traefik qui le possede, pas cette stack.
RESEAU_DU_PROXY := frontend

SCRIPT_DE_CONFIGURATION := bin/configurer_env.sh
SCRIPT_DE_VERIFICATION_DNS := bin/verifier_dns.sh
SCRIPT_D_ATTENTE        := bin/attendre.sh
SCRIPT_DE_SAUVEGARDE    := bin/backup.sh
SCRIPT_DE_VERIFICATION  := bin/verifier_archive.sh
SCRIPT_DE_REPETITION    := bin/check_backup.sh
SCRIPT_DE_RESTAURATION  := bin/restore.sh
SCRIPT_DE_MISE_A_JOUR   := bin/update.sh

.DEFAULT_GOAL := aide

.PHONY: aide install update backup backup-check verif-archive restore \
        logs status stop start .verif-docker

# Ce Makefile PILOTE Docker, il ne l'installe pas. Sans lui, chaque cible
# echouerait sur un « command not found » qui ne dit pas quoi faire.
# / This Makefile drives Docker; it does not install it.
.verif-docker:
	@command -v docker >/dev/null 2>&1 || { \
		echo ""; \
		echo "  Docker est introuvable sur cette machine."; \
		echo "  Ce Makefile pilote Docker depuis l'hote — il ne"; \
		echo "  l'installe pas. Voir https://docs.docker.com/engine/install/"; \
		echo ""; \
		exit 1; \
	}

##@ Aide

aide:  ## Affiche cette aide
	@echo ""
	@echo "  \033[1mAlexandrie\033[0m — a lancer depuis l'hote."
	@echo "  \033[2mLe Makefile appelle les scripts de bin/, il ne les recopie pas.\033[0m"
	@# Les CHIFFRES et les TIRETS comptent dans la classe : sans eux,
	@# `backup-check` serait absent de cette aide sans que rien ne le
	@# signale. Les sections viennent des lignes `##@`.
	@# / Digits and dashes matter in the class; sections come from `##@`.
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@ / {printf "\n  \033[1m%s\033[0m\n", substr($$0, 5)} \
		/^[a-zA-Z0-9_-]+:.*?## / \
		{printf "    \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  \033[1mOptions\033[0m"
	@echo "    CONFIRME=oui     saute les questions de update et backup-check"
	@echo "    ARCHIVE=<nom>    quelle archive restaurer (defaut : la derniere)"
	@echo "    S=<service>      cible un service : make logs S=backend"
	@echo ""
	@echo "  \033[1mLes deux controles de sauvegarde, et leur difference\033[0m"
	@echo "    \033[36mverif-archive\033[0m  ne touche a rien. Pour un cron, un monitoring."
	@echo "    \033[36mbackup-check\033[0m   ETEINT le site, detruit les volumes et"
	@echo "                   recharge la sauvegarde. C'est le seul qui prouve"
	@echo "                   qu'elle marche. Rien n'est perdu : l'archive"
	@echo "                   rechargee est prise juste avant."
	@echo ""

##@ Cycle de vie

install: .verif-docker  ## TOUT : .env + reseau + conteneurs + attente (idempotent)
	@# Le .env d'abord : docker compose le LIT. Sans lui, MYSQL_PASSWORD
	@# est vide et la base refuse de s'initialiser. Ce script ne fait rien
	@# si le fichier existe deja.
	@# / The .env first: compose reads it.
	@bash $(SCRIPT_DE_CONFIGURATION)
	@# Le reseau du proxy est `external:` : compose refuse de demarrer
	@# s'il n'existe pas, sur un message qui parle de reseau et pas de
	@# Traefik. On le cree, c'est sans effet s'il est deja la.
	@# / compose refuses to start without it, on a message that talks
	@# about a network and never about Traefik.
	@docker network inspect $(RESEAU_DU_PROXY) >/dev/null 2>&1 \
		|| { echo "[install] creation du reseau $(RESEAU_DU_PROXY)"; \
		     docker network create $(RESEAU_DU_PROXY) >/dev/null; }
	@# LE CONTROLE DNS PASSE AVANT LE PREMIER `up`, ET C'EST TOUT
	@# L'INTERET. Demarrer avant que les trois noms ne resolvent fait
	@# bruler le quota de Let's Encrypt — cinq echecs par nom et par
	@# heure — et le nom reste sans certificat pendant une heure, meme
	@# une fois le DNS corrige. Constate en production le 17 aout 2026.
	@# Apres le `up`, il serait trop tard : le mal est fait en quelques
	@# secondes. / Before the first `up`, because afterwards it is too
	@# late: the quota burns in seconds.
	@bash $(SCRIPT_DE_VERIFICATION_DNS)
	$(COMPOSE) up -d
	@bash $(SCRIPT_D_ATTENTE) 300
	@echo ""
	@echo "  Le site       : https://$$(sed -n 's/^DOMAIN=//p' .env | tail -n1)/"
	@echo "  Les journaux  : make logs"
	@echo ""
	@# IL N'Y A PAS DE NOTION DE PROPRIETAIRE. Ce message disait « le
	@# premier inscrit est le tien », ce qui est faux et trompeur :
	@# l'amont ne traite pas le premier compte differemment des autres,
	@# et le statut d'administrateur vient UNIQUEMENT d'ADMIN_ACCOUNTS.
	@# Qui s'arrete a la premiere phrase se retrouve sans acces admin sur
	@# sa propre instance.
	@# / There is no owner concept: admin status comes only from
	@# ADMIN_ACCOUNTS, and the first account is not special.
	@echo "  Aucun compte n'existe encore, et l'inscription est OUVERTE."
	@echo "  Sur une machine joignable de l'exterieur, faire les trois dans"
	@echo "  la foulee :"
	@echo "    1. s'inscrire"
	@echo "    2. relever son identifiant numerique (page de profil)"
	@echo "    3. dans le .env : ADMIN_ACCOUNTS=<cet identifiant>"
	@echo "                      CONFIG_DISABLE_SIGNUP=true"
	@echo "       puis : make install"
	@echo ""
	@echo "  S'inscrire en premier ne donne AUCUN privilege : sans l'etape 3,"
	@echo "  personne n'est administrateur de cette instance."
	@echo ""

update: .verif-docker  ## Met a jour les images, et verifie que ca tient
	@bash $(SCRIPT_DE_MISE_A_JOUR)

status: .verif-docker  ## Etat des quatre conteneurs
	@$(COMPOSE) ps

logs:  ## Suit les journaux, ou ceux d'un service : make logs S=backend
	@if [ -n "$(S)" ]; then $(COMPOSE) logs -f $(S); \
	else $(COMPOSE) logs -f; fi

stop: .verif-docker  ## Arrete la stack (les donnees restent)
	@$(COMPOSE) stop

start: .verif-docker  ## Redemarre une stack arretee
	@$(COMPOSE) start
	@bash $(SCRIPT_D_ATTENTE) 300

##@ Sauvegarde

backup:  ## Sauvegarde : base + fichiers + .env (se configure au 1er lancement)
	@bash $(SCRIPT_DE_SAUVEGARDE)

verif-archive:  ## La derniere archive est-elle restaurable ? (ne touche a rien)
	@bash $(SCRIPT_DE_VERIFICATION)

backup-check:  ## REPETITION GENERALE : eteint tout, recharge la sauvegarde, verifie
	@bash $(SCRIPT_DE_REPETITION)

restore:  ## ECRASE les donnees depuis une archive : make restore [ARCHIVE=<nom>]
	@bash $(SCRIPT_DE_RESTAURATION) $(ARCHIVE)
