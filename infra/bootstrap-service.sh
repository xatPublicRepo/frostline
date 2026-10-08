#!/bin/bash
# Creates the ECS service the pipeline deploys to, running a placeholder image.
#
#     bash infra/bootstrap-service.sh
#
# A pipeline updates a service that already exists. It does not create one. So
# this script makes, once, everything that stays the same between releases:
#
#   frostline-execution-role   the role ECS uses to pull the image and write logs
#   /ecs/frostline             the log group the container writes to
#   frostline-cluster          the ECS cluster
#   frostline-task-sg          a security group in the default VPC, port 8000 open
#   frostline                  the task definition family, revision 1 = placeholder
#   frostline-api              the Fargate service, one task, with a public IP
#
# The placeholder is a plain nginx image. It does not answer on port 8000. Your
# pipeline's first deploy replaces it with the frost alert service.
#
# Safe to run again: anything that already exists is left as it is.
set -u
REGION=us-west-2
export AWS_REGION=$REGION AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
A="aws --region $REGION"
PLACEHOLDER=public.ecr.aws/docker/library/nginx:stable-alpine

step() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOPPED: %s\n' "$*"; exit 1; }

step "Account"
ACCOUNT=$($A sts get-caller-identity --query Account --output text) || die "the AWS CLI is not signed in"
echo "account $ACCOUNT, region $REGION"

step "Task execution role frostline-execution-role"
if ! $A iam get-role --role-name frostline-execution-role >/dev/null 2>&1; then
    $A iam create-role --role-name frostline-execution-role \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        >/dev/null || die "could not create the role frostline-execution-role"
    echo "created"
else
    echo "already exists"
fi
$A iam attach-role-policy --role-name frostline-execution-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    || die "could not attach AmazonECSTaskExecutionRolePolicy"
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/frostline-execution-role"

step "Log group /ecs/frostline"
$A logs create-log-group --log-group-name /ecs/frostline 2>/dev/null && echo "created" || echo "already exists"
$A logs put-retention-policy --log-group-name /ecs/frostline --retention-in-days 1 2>/dev/null

step "Cluster frostline-cluster"
# On an account that has never used ECS, the first call can fail while AWS
# creates ECS's own service-linked role. Waiting and trying again fixes it.
for try in 1 2 3 4; do
    STATUS=$($A ecs create-cluster --cluster-name frostline-cluster --query cluster.status --output text 2>/tmp/frostline-cluster.err)
    [ "$STATUS" = ACTIVE ] && break
    echo "not ready yet ($(tail -n 1 /tmp/frostline-cluster.err | cut -c1-120)), trying again in 20 s"
    sleep 20
done
[ "$STATUS" = ACTIVE ] || die "the cluster could not be created"
echo "ACTIVE"

step "Security group frostline-task-sg in the default VPC"
VPC=$($A ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ -n "$VPC" ] && [ "$VPC" != None ] || die "this account has no default VPC in $REGION"
SUBNETS=$($A ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
    --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
[ -n "$SUBNETS" ] || die "the default VPC has no default subnets"
SG=$($A ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values=frostline-task-sg \
    --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$SG" ] || [ "$SG" = None ]; then
    SG=$($A ec2 create-security-group --vpc-id "$VPC" --group-name frostline-task-sg \
        --description "frostline tasks, port 8000 from anywhere" --query GroupId --output text) \
        || die "could not create the security group"
fi
$A ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8000 --cidr 0.0.0.0/0 >/dev/null 2>&1
echo "$SG in $VPC"

step "Task definition frostline (placeholder)"
if [ "$($A ecs list-task-definitions --family-prefix frostline --query 'length(taskDefinitionArns)' --output text)" = 0 ]; then
    $A ecs register-task-definition --family frostline \
        --requires-compatibilities FARGATE --network-mode awsvpc --cpu 256 --memory 512 \
        --runtime-platform cpuArchitecture=X86_64,operatingSystemFamily=LINUX \
        --execution-role-arn "$EXEC_ROLE_ARN" \
        --container-definitions "[{\"name\":\"frostline\",\"image\":\"$PLACEHOLDER\",\"essential\":true,
            \"portMappings\":[{\"containerPort\":8000,\"protocol\":\"tcp\"}],
            \"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/frostline\",
            \"awslogs-region\":\"$REGION\",\"awslogs-stream-prefix\":\"ecs\"}}}]" \
        --query 'taskDefinition.[family, revision]' --output text || die "could not register the task definition"
else
    echo "already registered"
fi

step "Service frostline-api"
SVC=$($A ecs describe-services --cluster frostline-cluster --services frostline-api \
    --query 'services[0].status' --output text 2>/dev/null)
if [ "$SVC" != ACTIVE ]; then
    $A ecs create-service --cluster frostline-cluster --service-name frostline-api \
        --task-definition frostline --desired-count 1 --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
        --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
        --query 'service.status' --output text || die "could not create the service"
else
    echo "already exists"
fi
echo "waiting for the service to be stable (about a minute)"
$A ecs wait services-stable --cluster frostline-cluster --services frostline-api \
    && echo "stable" || echo "not stable yet; check the service's Events tab in the console"

step "Done"
echo "Your pipeline deploys to cluster frostline-cluster, service frostline-api,"
echo "task definition family frostline, container frostline, in $REGION."
echo "The execution role your deploy role must be allowed to pass is:"
echo "  $EXEC_ROLE_ARN"
