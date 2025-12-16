# Service log utility function
svclog() {
    # %F is YYYY-MM-DD, %T is HH:MM:SS
    #printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "${BASE}/logs/svc-${HOSTNAME}.log"
    # ISO 8601 format
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')" "$*" | tee -a "${BASE}/logs/svc-${HOSTNAME}.log"
}

redate () {
    # Convert a timestamp from "YYYY-MM-DD HH:MM:SS" to "YYYY-MM-DDTHH:MM:SSZ" format
    sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) /\1T\2Z /'
}
