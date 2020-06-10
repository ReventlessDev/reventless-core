#!/bin/sh
echo "--- run pulumi up ---"

# get the token from .env file
PULUMI_ACCESS_TOKEN_ENV=`cat .env | grep ^PULUMI_ACCESS_TOKEN | cut -d '=' -f 2`

# export token from .env file
if [ "$PULUMI_ACCESS_TOKEN_ENV" != "" ]; then
	export PULUMI_ACCESS_TOKEN=$PULUMI_ACCESS_TOKEN_ENV
fi

# throw error and exit, if token is not set
if [ "$PULUMI_ACCESS_TOKEN" == "" ]; then
	echo "ERROR: Make sure to set your env var for PULUMI_ACCESS_TOKEN or set it in the project's .env file!"
	exit 1
fi

# get the stack name from .env file
PULUMI_STACK=`cat .env | grep ^PULUMI_STACK | cut -d '=' -f 2`

# throw error and exit, if stack is not set
if [ "$PULUMI_STACK" == "" ]; then
	echo "ERROR: Make sure to set PULUMI_STACK in the project's .env file!"
	exit 1
fi

# actually start deployment
txt="run pulumi up -s "
echo $txt$PULUMI_STACK
pulumi up -s $PULUMI_STACK & wait $!
