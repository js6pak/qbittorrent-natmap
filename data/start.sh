#!/usr/bin/env bash

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

getpublicip() {
    natpmpc | grep -oP '(?<=Public.IP.address.:.).*'
}

findconfiguredport() {
    curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "$1" http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/preferences | grep -oP '(?<=\"listen_port\"\:)(\d{1,5})'
}

findactiveport() {
    natpmpc -a 0 0 udp ${NAT_LEASE_LIFETIME} >/dev/null 2>&1
    natpmpc -a 0 0 tcp ${NAT_LEASE_LIFETIME} | grep -oP '(?<=Mapped public port.).*(?=.protocol.*)'
}

qbt_login() {
    curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --data "username=${QBITTORRENT_USER}&password=${QBITTORRENT_PASS}" http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login | grep -oP '(?!set-cookie:.)SID=.*(?=\;.HttpOnly\;.path=\/\;)'
}

qbt_changeport(){
    curl -s -i --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "$1" --data-urlencode "json={\"listen_port\":$2,\"random_port\":false,\"upnp\":false}" http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences 2>&1 >/dev/null
    return $?
}

qbt_checksid(){
    if echo $(curl -s --header "Referer: http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}" --cookie "${qbt_sid}" http://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/version) | grep -qi forbidden; then
        return 1
    else
        return 0
    fi
}

qbt_isreachable(){
    nc -4 -vw 5 ${QBITTORRENT_SERVER} ${QBITTORRENT_PORT} 2>&1 &>/dev/null
}

fw_delrule(){
    if (docker exec ${VPN_CT_NAME} /sbin/iptables -L INPUT -n | grep -qP "^ACCEPT.*${configured_port}.*"); then
        docker exec ${VPN_CT_NAME} /sbin/iptables -D INPUT -i ${VPN_IF_NAME} -p tcp --dport ${configured_port} -j ACCEPT
        docker exec ${VPN_CT_NAME} /sbin/iptables -D INPUT -i ${VPN_IF_NAME} -p udp --dport ${configured_port} -j ACCEPT
    fi
}

fw_addrule(){
    if ! (docker exec ${VPN_CT_NAME} /sbin/iptables -L INPUT -n | grep -qP "^ACCEPT.*${active_port}.*"); then
        docker exec ${VPN_CT_NAME} /sbin/iptables -A INPUT -i ${VPN_IF_NAME} -p tcp --dport ${active_port} -j ACCEPT
        docker exec ${VPN_CT_NAME} /sbin/iptables -A INPUT -i ${VPN_IF_NAME} -p udp --dport ${active_port} -j ACCEPT
        return 0
    else
        return 1
    fi
}

get_portmap() {
    res=0
    public_ip=$(getpublicip)

    if ! qbt_checksid; then
        echo "$(timestamp) | qBittorrent Cookie invalid, getting new SessionID"
        qbt_sid=$(qbt_login)
    else
        echo "$(timestamp) | qBittorrent SessionID Ok!"
    fi

    configured_port=$(findconfiguredport ${qbt_sid})
    active_port=$(findactiveport)

    echo "$(timestamp) | Public IP: ${public_ip}"
    echo "$(timestamp) | Configured Port: ${configured_port}"
    echo "$(timestamp) | Active Port: ${active_port}"

    if [ ${configured_port} != ${active_port} ]; then
        if qbt_changeport ${qbt_sid} ${active_port}; then
            if fw_delrule; then
                echo "$(timestamp) | IPTables rule deleted for port ${configured_port} on ${VPN_CT_NAME} container"
            fi
            echo "$(timestamp) | Port Changed to: $(findconfiguredport ${qbt_sid})"
        else
            echo "$(timestamp) | Port Change failed."
            res=1
        fi
    else
        echo "$(timestamp) | Port OK (Act: ${active_port} Cfg: ${configured_port})"
    fi

    if fw_addrule; then
        echo "$(timestamp) | IPTables rule added for port ${active_port} on ${VPN_CT_NAME} container"
    fi

    return $res
}

pre_reqs() {
while read var; do
    [ -z "${!var}" ] && { echo "$(timestamp) | ${var} is empty or not set."; exit 1; }
done << EOF
QBITTORRENT_SERVER
QBITTORRENT_PORT
QBITTORRENT_USER
QBITTORRENT_PASS
VPN_CT_NAME
VPN_IF_NAME
CHECK_INTERVAL
NAT_LEASE_LIFETIME
EOF

[ ! -S /var/run/docker.sock ] && { echo "$(timestamp) | Docker socket doesn't exist or is inaccessible"; exit 2; }

return 0
}

load_vals(){
    public_ip=$(getpublicip)
    if qbt_isreachable; then
        qbt_sid=$(qbt_login)
        configured_port=$(findconfiguredport ${qbt_sid})
    else
        echo "$(timestamp) | Unable to reach qBittorrent at ${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}"
        exit 6
    fi
    active_port=''
}

if pre_reqs; then load_vals; fi

[ -z ${public_ip} ] && { echo "$(timestamp) | Unable to grab VPN Public IP. Please check configuration"; exit 3; }
[ -z ${configured_port} ] && { echo "$(timestamp) | qBittorrent configured port value is empty(?). Please check configuration"; exit 4; }
[ -z ${qbt_sid} ] && { echo "$(timestamp) | Unable to grab qBittorrent SessionID. Please check configuration"; exit 5; }

while true;
do
    if get_portmap; then
        echo "$(timestamp) | NAT-PMP/UPnP Ok!"
    else
        echo "$(timestamp) | NAT-PMP/UPnP Failed"
    fi
    echo "$(timestamp) | Sleeping for $(echo ${CHECK_INTERVAL}/60 | bc) minutes"
    sleep ${CHECK_INTERVAL}
done

exit $?
