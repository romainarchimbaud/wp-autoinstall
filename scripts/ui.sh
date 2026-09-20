# Écrans whiptail communs à make setup, aux synchros et à make ssh-alias (sourcé, pas exécuté).
# Le script appelant définit WT_TITLE. ask : 0 = Valider, 1 = Retour, 255 = Échap (tout annuler).
# Thème sombre (fond du terminal, accents bleus) au lieu du rose par défaut de whiptail
export NEWT_COLORS='root=white,default border=brightblue,default window=white,default shadow=default,default
title=brightcyan,default button=white,gray actbutton=white,blue compactbutton=white,default
checkbox=white,default actcheckbox=white,blue entry=white,gray disentry=gray,default label=white,default
listbox=white,default actlistbox=white,blue sellistbox=brightcyan,default actsellistbox=white,blue
textbox=white,default acttextbox=white,blue helpline=white,default roottext=white,default'
ask() {
	whiptail --backtitle "Entrée : valider    Retour : question précédente    Échap : tout annuler" \
		--title "$WT_TITLE" --ok-button Valider --cancel-button Retour "$@" 3>&1 1>&2 2>&3
}
