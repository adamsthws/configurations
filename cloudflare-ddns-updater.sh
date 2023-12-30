#!/usr/bin/env bash

# Enable Bash strict mode
# https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

## Import enviroment variables (api key etc)
source .env

## API token
## (imported from .env file)
api_token=$API_KEY

## The email address associated with the Cloudflare account; e.g. email@gmail.com
## (imported from .env file)
email=$EMAIL

## the zone (domain) should be modified; e.g. example.com
## (imported from .env file)
zone_name=$ZONE_NAME

## the dns record (sub-domain) that needs to be modified; e.g. sub.example.com
## (imported from .env file)
dns_record=$DNS_RECORD

# Notification message
error_msg="Script Error (Cloudflare DYNdns updater script)."
success_msg="Script Success (Cloudflare DYNdns updater script)."

# Debug function to print messages based on debug level
debug() {
    if [[ $DEBUG_LEVEL -eq 2 ]]; then
        echo "$1"
    elif [[ $DEBUG_LEVEL -gt 0 ]]; then
        echo "$1" >&2
    fi
}

# Error function to print errors
error() {
    echo -e "$1" >&2
}

# Set debug mode if debug level > 0
if [[ $DEBUG_LEVEL -gt 0 ]]; then
    set -x
fi

# Check if the script is already running
if ps ax | grep "$0" | grep -v "$$" | grep bash | grep -v grep > /dev/null; then
    error "The script is already running."
    exit 1
fi

# Check if jq is installed
check_jq=$(which jq)
if [ -z "${check_jq}" ]; then
    >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \njq is not installed. Install it by 'sudo apt install jq'."
    exit 1
fi

# Check the subdomain
# Check if the dns_record field (subdomain) contains dot
if [[ $dns_record == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $dns_record != *.$zone_name ]]; then
        >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nThe Zone in DNS Record does not match the defined Zone; check it and try again."
        exit 1
    fi
# check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $dns_record =~ ^[a-zA-Z0-9-]+$ ]]; then
    >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nThe DNS Record contains illegal charecters, i.e., @, %, *, _, etc.; fix it and run the script again."
    exit 1
# if the dns_record (subdomain) is not complete, complete it
else
    dns_record="$dns_record.$zone_name"
fi

# Check if DNS Records Exists
check_record_ipv4=$(dig -t a +short ${dns_record} | tail -n1)

# get the basic data
ipv4=$(curl -s -X GET https://checkip.amazonaws.com)
user_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
               -H "Authorization: Bearer $api_token" \
               -H "Content-Type:application/json" \
          | jq -r '{"result"}[] | .id'
         )

# Check public IPv4 is obtainable
if [ $ipv4 ]; then
    # If running as chron stay silent. Otherwise output result.
    if [ -t 1 ] ; then
        echo -e "Current public IPv4 address: $ipv4"
    fi
else
    >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nUnable to get any public IPv4 address."
    exit 1
fi

# Check if the user API is valid and the email is correct
if [ $user_id ]; then
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active" \
                   -H "Content-Type: application/json" \
                   -H "X-Auth-Email: $email" \
                   -H "Authorization: Bearer $api_token" \
              | jq -r '{"result"}[] | .[0] | .id'
             )
    # check if the zone ID is avilable
    if [ $zone_id ]; then
        # check if there is IPv4
        if [ $ipv4 ]; then
            # Check if A Record exists
            if [ -z "${check_record_ipv4}" ]; then
                >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nNo A Record is setup for ${dns_record}."
                exit 1
            fi
            dns_record_a_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$dns_record"  \
                                   -H "Content-Type: application/json" \
                                   -H "X-Auth-Email: $email" \
                                   -H "Authorization: Bearer $api_token"
                             )
            dns_record_a_ip=$(echo $dns_record_a_id |  jq -r '{"result"}[] | .[0] | .content')
            # Check if the machine's IPv4 is different to the Cloudflare IPv4
            if [ $dns_record_a_ip != $ipv4 ]; then
                # If IPv4 is different, update the A record
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$(echo $dns_record_a_id | jq -r '{"result"}[] | .[0] | .id')" \
                     -H "Content-Type: application/json" \
                     -H "X-Auth-Email: $email" \
                     -H "Authorization: Bearer $api_token" \
                     --data "{\"type\":\"A\",\"name\":\"$dns_record\",\"content\":\"$ipv4\",\"ttl\":1,\"proxied\":false}" \
                | jq -r '.errors'
                # Wait for 180 seconds to allow the DNS change to propogate / become active
                sleep 180
                # Check the IPv4 change has been applied sucessfully
                if [ $check_record_ipv4 != $ipv4 ]; then
                    >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nA change of IP was attempted but was unsuccessful. \nCurrent IP: $ipv4 \nCloudflare IP: $check_record_ipv4"
                    exit 1
                # Output result (stays silent if executed from cron-job)
                elif [ -t 1 ] ; then
                    echo -e "Script Notification (Cloudflare DYNdns updater script) \nUpdated: IPv4 successfully set on Cloudflare with the value of: $ipv4."
                    exit 0
                fi

            else
                # Output result (stays silent if executed from cron-job)
                if [ -t 1 ] ; then
                    echo -e "Script Success (Cloudflare DYNdns updater script) \nNo change: The current IPv4 address matches the IP at Cloudflare: $ipv4."
                    exit 0
                fi
            fi
        fi

    else
        >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nThere is a problem with getting the Zone ID (sub-domain) or the email address (username)."
        exit 1
    fi
else
    >&2 echo -e "Script Error (Cloudflare DYNdns updater script) \nThere is a problem with the API token."
    exit 1
fi