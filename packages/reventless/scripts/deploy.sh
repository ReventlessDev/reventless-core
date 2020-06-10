#!/bin/sh
echo "- Start Deployment Script -"
./scripts/pre-deploy.sh &&
./scripts/pulumi-up.sh
./scripts/post-deploy.sh &&
echo "end of deployment script"
