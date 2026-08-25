SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# =============================================================================
# Fraud Detection (Bedrock AgentCore + Lambda Durable Functions) - LocalStack
# =============================================================================
#
# Deploys this sample to a local LocalStack instance instead of real AWS.
# Mirrors deploy-sam.sh, but builds/uploads artifacts and runs `sam` against
# LocalStack's endpoint instead of AWS.
#
# Tooling: by default this uses the plain `sam`/`aws` CLIs with
# AWS_ENDPOINT_URL pointed at LocalStack. If you prefer the `samlocal`/
# `awslocal` wrapper scripts instead, override on the command line:
#   make deploy SAM=samlocal AWSCLI=awslocal
#
# Caveat: AWS::BedrockAgentCore::Runtime and Lambda DurableConfig are both
# very recent AWS features. Check `make check` / your LocalStack version's
# release notes if the agent runtime or durable execution steps fail.
#
# Payment capture (the `authorize` step) runs against the LocalStack Stripe
# extension by default, so the whole workflow - fraud scoring AND payment -
# runs locally with no real Stripe account needed. Requires a LocalStack Pro
# auth token; run `make install-stripe-extension` once before `make start`.
# To deploy without payment capture, pass STRIPE_SECRET_KEY= (empty).
#
# Note: recipes below use classic backslash line-continuations (one shell
# invocation per target) rather than .ONESHELL, since GNU Make 3.81 (macOS's
# stock /usr/bin/make) predates .ONESHELL support.
#
# Run `make help` to list all targets.
# =============================================================================

# --- App configuration (matches template.yaml / samconfig.toml defaults) ---
STACK_NAME         ?= fraud-detection-durable-function
FUNCTION_NAME       ?= fn-Fraud-Detection
LAYER_NAME          ?= lr-FraudDetection
ROLE_NAME           ?= durable-function-execution-role
AGENT_RUNTIME_NAME  ?= fraud_risk_scorer
AGENT_ROLE_NAME     ?= bedrock-agentcore-runtime-fraud-role
ECR_REPO_NAME       ?= fraud-risk-scorer
LAMBDA_REGION       ?= us-east-1
AGENT_REGION        ?= us-east-1
EXECUTION_TIMEOUT   ?= 90000
RETENTION_DAYS      ?= 7
PLATFORM            ?= linux/arm64

# AWS::BedrockAgentCore::Runtime isn't natively emulated by LocalStack yet (it's accepted
# via a generic fallback whose GetAtt attributes don't resolve to real values), which
# breaks the IAM policy that references AgentRuntime.AgentRuntimeArn. Supply a
# placeholder ARN instead so the stack can still deploy; real invocations of the agent
# will fail, but the workflow already falls back to a default risk score in that case
# (or pass an explicit `score` in the invoke payload to skip the agent call entirely).
AGENT_RUNTIME_ARN_OVERRIDE ?= arn:aws:bedrock-agentcore:$(AGENT_REGION):$(ACCOUNT_ID):runtime/$(AGENT_RUNTIME_NAME)

# Stripe payment capture (the `authorize` step). Defaults point at the LocalStack
# Stripe extension so the whole workflow runs locally; set STRIPE_SECRET_KEY= to
# disable payment capture entirely, or point STRIPE_HOST= (empty) + a real key at
# api.stripe.com.
STRIPE_SECRET_KEY   ?= sk_test_localstack
STRIPE_HOST         ?= stripe.localhost.localstack.cloud

# --- LocalStack connection ---------------------------------------------
ACCOUNT_ID   ?= 000000000000
ENDPOINT_URL ?= http://localhost.localstack.cloud:4566
SAM          ?= sam
AWSCLI       ?= aws

export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION    ?= $(LAMBDA_REGION)
export AWS_ENDPOINT_URL      ?= $(ENDPOINT_URL)

BUCKET_NAME   := durable-functions-$(ACCOUNT_ID)
ECR_REGISTRY  := $(ACCOUNT_ID).dkr.ecr.$(AGENT_REGION).localhost.localstack.cloud:4566
ECR_URI       := $(ECR_REGISTRY)/$(ECR_REPO_NAME)

# --- Invocation defaults (see invoke-function.sh / send-callback.sh) ----
TX_ID    ?= $(shell date +%s)
AMOUNT   ?= 5000.00
LOCATION ?= New York, NY
VENDOR   ?= Amazon.com
SCORE    ?= 0
STATUS   ?= approve

.PHONY: help check start stop install-stripe-extension build build-agent build-lambda deploy outputs \
        invoke callback executions logs clean delete

help: ## Show this help
	@echo "Fraud Detection sample - LocalStack deployment"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make deploy"
	@echo "  make invoke AMOUNT=6500"
	@echo "  make callback CALLBACK_ID=<id> STATUS=approve"

check: ## Verify required tools are installed and LocalStack is reachable
	@ok=1; \
	for tool in docker jq $(SAM) $(AWSCLI); do \
		command -v "$$tool" >/dev/null 2>&1 || { echo "Missing tool: $$tool" >&2; ok=0; }; \
	done; \
	if ! curl -sf "$(ENDPOINT_URL)/_localstack/health" >/dev/null; then \
		echo "LocalStack not reachable at $(ENDPOINT_URL) (run 'make start')." >&2; \
		ok=0; \
	fi; \
	if [ -n "$(STRIPE_HOST)" ] && ! curl -sf -u "$(STRIPE_SECRET_KEY):" "$(ENDPOINT_URL)/stripe/v1/customers" >/dev/null; then \
		echo "Stripe extension not reachable via $(ENDPOINT_URL)/stripe (run 'make install-stripe-extension' then restart LocalStack), or set STRIPE_SECRET_KEY= to deploy without payment capture." >&2; \
		ok=0; \
	fi; \
	[ "$$ok" = "1" ] && echo "OK: tools installed, LocalStack reachable at $(ENDPOINT_URL)."

start: ## Start LocalStack in the background (idempotent)
	@if curl -sf "$(ENDPOINT_URL)/_localstack/health" >/dev/null 2>&1; then \
		echo "LocalStack is already running."; \
	else \
		localstack start -d; \
		localstack wait -t 60; \
	fi

stop: ## Stop LocalStack
	@localstack stop

install-stripe-extension: ## Install the LocalStack Stripe extension (one-time; requires a Pro auth token)
	@localstack extensions install localstack-extension-stripe

# Note: build with --load (into the host docker daemon) then a separate `docker push`,
# rather than `buildx build --push`. A --push straight out of buildx runs inside an
# isolated buildkit builder container that can't reach LocalStack on 127.0.0.1; --load
# puts the image in the same host daemon that `docker login` above already authenticated.
build-agent: ## Build & push the Bedrock AgentCore fraud-scoring image to the local ECR
	@cd FraudDetection-Agent; \
	echo "Ensuring ECR repository $(ECR_REPO_NAME) exists..."; \
	$(AWSCLI) ecr describe-repositories --repository-names $(ECR_REPO_NAME) --region $(AGENT_REGION) >/dev/null 2>&1 || \
		$(AWSCLI) ecr create-repository --repository-name $(ECR_REPO_NAME) --region $(AGENT_REGION) >/dev/null; \
	echo "Logging in to $(ECR_REGISTRY)..."; \
	$(AWSCLI) ecr get-login-password --region $(AGENT_REGION) | docker login --username AWS --password-stdin $(ECR_REGISTRY); \
	echo "Building $(ECR_URI):latest ($(PLATFORM))..."; \
	docker buildx build --platform $(PLATFORM) -t $(ECR_URI):latest --load .; \
	echo "Pushing $(ECR_URI):latest..."; \
	docker push $(ECR_URI):latest

build-lambda: ## Build the durable Lambda function + layer zips and upload to S3
	@cd FraudDetection-Lambda; \
	echo "Cleaning previous build..."; \
	rm -rf node_modules dist function.zip layer.zip; \
	echo "Installing dependencies..."; \
	npm install --silent; \
	echo "Compiling TypeScript..."; \
	npx tsc; \
	echo "Packaging function.zip..."; \
	(cd dist && zip -qr ../function.zip .); \
	zip -q function.zip package.json; \
	echo "Packaging layer.zip..."; \
	mkdir -p layer/nodejs; \
	cp -r node_modules layer/nodejs/; \
	(cd layer && zip -qr ../layer.zip .); \
	echo "Ensuring S3 bucket $(BUCKET_NAME) exists..."; \
	if ! $(AWSCLI) s3api head-bucket --bucket $(BUCKET_NAME) --region $(LAMBDA_REGION) 2>/dev/null; then \
		if [ "$(LAMBDA_REGION)" = "us-east-1" ]; then \
			$(AWSCLI) s3api create-bucket --bucket $(BUCKET_NAME) --region $(LAMBDA_REGION) >/dev/null; \
		else \
			$(AWSCLI) s3api create-bucket --bucket $(BUCKET_NAME) --region $(LAMBDA_REGION) \
				--create-bucket-configuration LocationConstraint=$(LAMBDA_REGION) >/dev/null; \
		fi; \
		$(AWSCLI) s3api put-bucket-versioning --bucket $(BUCKET_NAME) --region $(LAMBDA_REGION) \
			--versioning-configuration Status=Enabled; \
	fi; \
	echo "Uploading packages to S3..."; \
	$(AWSCLI) s3 cp function.zip s3://$(BUCKET_NAME)/functions/$(FUNCTION_NAME).zip --region $(LAMBDA_REGION); \
	$(AWSCLI) s3 cp layer.zip s3://$(BUCKET_NAME)/layers/$(LAYER_NAME).zip --region $(LAMBDA_REGION)

build: build-agent build-lambda ## Build the agent image and the Lambda package

deploy: build ## Build artifacts and deploy the SAM stack to LocalStack
	@echo "Deploying stack $(STACK_NAME) to LocalStack..."; \
	$(SAM) deploy \
		--template-file template.yaml \
		--stack-name $(STACK_NAME) \
		--region $(LAMBDA_REGION) \
		--capabilities CAPABILITY_NAMED_IAM \
		--no-fail-on-empty-changeset \
		--parameter-overrides \
			FunctionName=$(FUNCTION_NAME) \
			LayerName=$(LAYER_NAME) \
			RoleName=$(ROLE_NAME) \
			AgentRuntimeName=$(AGENT_RUNTIME_NAME) \
			AgentRoleName=$(AGENT_ROLE_NAME) \
			ECRRepoName=$(ECR_REPO_NAME) \
			LambdaRegion=$(LAMBDA_REGION) \
			AgentRegion=$(AGENT_REGION) \
			ExecutionTimeout=$(EXECUTION_TIMEOUT) \
			RetentionPeriodInDays=$(RETENTION_DAYS) \
			StripeSecretKey=$(STRIPE_SECRET_KEY) \
			StripeHost=$(STRIPE_HOST) \
			AgentRuntimeArnOverride=$(AGENT_RUNTIME_ARN_OVERRIDE)
	@$(MAKE) --no-print-directory outputs

outputs: ## Print the deployed stack's outputs (function ARN, agent runtime ARN, ...)
	@$(AWSCLI) cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(LAMBDA_REGION) \
		--query 'Stacks[0].Outputs' --output table

invoke: ## Invoke the durable function asynchronously (vars: TX_ID, AMOUNT, LOCATION, VENDOR, SCORE)
	@jq -n --argjson id "$(TX_ID)" --argjson amount "$(AMOUNT)" \
		--arg location "$(LOCATION)" --arg vendor "$(VENDOR)" --argjson score "$(SCORE)" \
		'{id:$$id, amount:$$amount, location:$$location, vendor:$$vendor, score:$$score}' > .invoke-payload.json; \
	echo "Invoking $(FUNCTION_NAME) (durable-execution-name: tx-$(TX_ID)) with:"; \
	cat .invoke-payload.json | jq .; \
	$(AWSCLI) lambda invoke \
		--function-name "$(FUNCTION_NAME):\$$LATEST" \
		--invocation-type Event \
		--durable-execution-name "tx-$(TX_ID)" \
		--payload fileb://.invoke-payload.json \
		--region $(LAMBDA_REGION) \
		response.json; \
	rm -f .invoke-payload.json; \
	cat response.json; \
	rm -f response.json

callback: ## Send a human-verification callback (required: CALLBACK_ID; optional: STATUS=approve|reject)
	@if [ -z "$(CALLBACK_ID)" ]; then \
		echo "CALLBACK_ID is required, e.g.: make callback CALLBACK_ID=<id> STATUS=approve" >&2; \
		exit 1; \
	fi; \
	case "$(STATUS)" in \
		approve) \
			$(AWSCLI) lambda send-durable-execution-callback-success \
				--callback-id "$(CALLBACK_ID)" \
				--result '{"status":"approved","message":"Transaction approved by user"}' \
				--region $(LAMBDA_REGION) ;; \
		reject) \
			$(AWSCLI) lambda send-durable-execution-callback-failure \
				--callback-id "$(CALLBACK_ID)" \
				--error '{"ErrorType":"UserRejection","ErrorMessage":"Transaction rejected by user"}' \
				--region $(LAMBDA_REGION) ;; \
		*) \
			echo "STATUS must be 'approve' or 'reject' (got '$(STATUS)')" >&2; \
			exit 1 ;; \
	esac

executions: ## List durable executions for the function
	@$(AWSCLI) lambda list-durable-executions-by-function --function-name $(FUNCTION_NAME) --region $(LAMBDA_REGION)

logs: ## Tail CloudWatch logs for the Lambda function (FOLLOW=1 to stream continuously)
	@if [ "$${FOLLOW:-0}" = "1" ]; then \
		$(AWSCLI) logs tail /aws/lambda/$(FUNCTION_NAME) --region $(LAMBDA_REGION) --follow; \
	else \
		$(AWSCLI) logs tail /aws/lambda/$(FUNCTION_NAME) --region $(LAMBDA_REGION) --since 1h; \
	fi

clean: ## Remove local build artifacts (zips, node_modules, dist, layer/, response.json)
	@rm -rf FraudDetection-Lambda/node_modules FraudDetection-Lambda/dist FraudDetection-Lambda/layer \
		FraudDetection-Lambda/function.zip FraudDetection-Lambda/layer.zip response.json .invoke-payload.json

delete: ## Delete the CloudFormation stack from LocalStack
	@$(SAM) delete --stack-name $(STACK_NAME) --region $(LAMBDA_REGION) --no-prompts
