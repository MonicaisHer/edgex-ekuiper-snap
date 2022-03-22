#!/bin/bash

set -e

LOG_PREFIX=$SNAP_INSTANCE_NAME:configure-kuiper

logger "$LOG_PREFIX: started"

for var in VAULT_TOKEN_FILE SOURCE_FILE CONNECTION_FILE ; do
	if [ -z "${!var}" ] ; then
		logger --stderr "$LOG_PREFIX: $var is not set"
		exit 1
	fi
done

handle_error()
{
	local EXIT_CODE=$1
	local ITEM=$2
	local RESPONSE=$3
	if [ $EXIT_CODE -ne 0 ] ; then
		logger --stderr "$LOG_PREFIX: $ITEM exited with code $EXIT_CODE: $RESPONSE"
		exit 1
	fi
}

# use Vault token query Redis token, access edgexfoundry secure Message Bus
if [ -f "$VAULT_TOKEN_FILE" ] ; then
	# get Vault token and create redis.yaml
	logger "$LOG_PREFIX: using Vault token to query Redis token"
	TOKEN=$(yq "$VAULT_TOKEN_FILE" | yq ' .auth.client_token')
	handle_error $? "yq" $TOKEN

	# check CURL's exit code
	CURL_RES=$(curl --silent --write-out "%{http_code}" \
	--header "X-Vault-Token: $TOKEN" \
	--request GET http://localhost:8200/v1/secret/edgex/edgex-ekuiper/redisdb)
	handle_error $? "curl" $CURL_RES

	# check response http code
	HTTP_CODE="${CURL_RES:${#CURL_RES}-3}"
	if [ $HTTP_CODE -ne 200 ] ; then
		logger --stderr "$LOG_PREFIX: http error $HTTP_CODE, with response: $CURL_RES"
		exit 1
	fi

	# get CURL's reponse
	if [ ${#CURL_RES} -eq 3 ]; then
		logger --stderr "$LOG_PREFIX: unexpected http response with empty body"
		exit 1
	else
		BODY="${CURL_RES:0:${#CURL_RES}-3}"
	fi

	# process the reponse and check if yq works
	REDIS_USER=$(echo $BODY| yq '.data.username')
	handle_error $? "yq" $REDIS_USER
	REDIS_PASS=$(echo $BODY| yq '.data.password')
	handle_error $? "yq" $REDIS_PASS

	# pass generated Redis credentials to configuration files
	logger "$LOG_PREFIX: adding Redis credentials to $SOURCE_FILE"
	YQ_RES=$(yq -i '.default += {"optional":{"Username":"'$REDIS_USER'"}+{"Password":"'$REDIS_PASS'"}}' "$SOURCE_FILE")
	handle_error $? "yq" $YQ_RES
	
	logger "$LOG_PREFIX: adding Redis credentials to $CONNECTION_FILE"
	YQ_RES=$(yq -i '.edgex.redisMsgBus += {"optional":{"Username":"'$REDIS_USER'"}+{"Password":"'$REDIS_PASS'"}}' "$CONNECTION_FILE")
	handle_error $? "yq" $YQ_RES

	logger "$LOG_PREFIX: configured eKuiper to authenticate with Redis, using credentials fetched from Vault"
else
	logger --stderr "$LOG_PREFIX: unable to configure eKuiper to authenticate with Redis: unable to query Redis token from Vault: Vault token not available"
fi

exec "$@"

