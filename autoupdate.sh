#!/bin/bash
UPDATE_VERSION=13
get_asset() {
    curl -s -f "https://api.github.com/repos/LucRtheL/deepfakemurk/contents/$1" | jq -r ".content" | base64 -d
}
get_built_asset(){
    curl -SLk "https://github.com/LucRtheL/deepfakemurk/releases/latest/download/$1"
}
install() {
    TMP=$(mktemp)
    get_asset "$1" >"$TMP"
    if [ "$?" == "1" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "failed to install $1 to $2"
        rm -f "$TMP"
        return 1
    fi
    # don't mv, as that would break permissions i spent so long setting up
    cat "$TMP" >"$2"
    rm -f "$TMP"
}
install_built() {
    TMP=$(mktemp)
    get_built_asset "$1" >"$TMP"
    if [ "$?" == "1" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "failed to install $1 to $2"
        rm -f "$TMP"
        return 1
    fi
    cat "$TMP" >"$2"
    rm -f "$TMP"
}

update_files() {
    install "fakemurk-daemon.sh" /sbin/fakemurk-daemon.sh
    install "chromeos_startup.sh" /sbin/chromeos_startup.sh
    install "mush.sh" /usr/bin/crosh
    install "pre-startup.conf" /etc/init/pre-startup.conf
    install "cr50-update.conf" /etc/init/cr50-update.conf
    install "lib/ssd_util.sh" /usr/share/vboot/bin/ssd_util.sh
    install_built "image_patcher.sh" /sbin/image_patcher.sh
    chmod 777 /sbin/fakemurk-daemon.sh /sbin/chromeos_startup.sh /usr/bin/crosh /usr/share/vboot/bin/ssd_util.sh /sbin/image_patcher.sh


}

autoupdate() {
    update_files
}

if [ "$0" = "$BASH_SOURCE" ]; then
    autoupdate
fi
