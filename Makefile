include .bingo/Variables.mk
.DEFAULT_GOAL := ci

## setup: set up all dependencies a developer needs
setup: setup-mac
setup-mac: local-setup-base
	# install xbar and argo monitor
	@go build -mod vendor -o ./xbar/argo ./cmd/status/argo/*.go
	@brew install -q xbar
	@rm -f "$$HOME/Library/Application Support/xbar/plugins/argo.1m.cgo"
	# READ ME🚨: if the next command says no such file or directory, run this in your terminal: open /Applications/xbar.app
	ln -sf "${CURDIR}/xbar/argo" "$$HOME/Library/Application Support/xbar/plugins/argo.3m.cgo"

setup-ubuntu: local-setup-base

local-setup-base: setup-ci
	@git config core.hooksPath .hooks
	@git config --global url."git@github.com:saltpay".insteadOf https://github.com/saltpay
	brew install -q jq yq adr-tools ctlptl helm kind kubernetes-cli tilt gpg git-crypt

setup-ci:
	@CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ./build/util ./cmd/util
	@echo Installing tools from tools.go
	@cat tools.go | grep _ | awk -F'"' '{print $$2}' | xargs -tI % go install %
	go install github.com/bwplotka/bingo@latest
	bingo get -l github.com/bwplotka/bingo@v0.6.0
	bingo get
	@# symlink the tools so that we don't need to provide versions in our code etc
	bingo get -l moq
	bingo get -l chartversion

ci:
	@git pull -r && make setup-ci test && git push

t: test
test: lint
	@make unit-test integration-test acceptance-test
test-nolint:
	@make unit-test integration-test acceptance-test
start: dev
dev:
	@ctlptl apply -f ./local/k8s/kind-cluster.yaml
	@tilt up

dev-ci: health-deps
	@LOAD_ENV=local go run ./cmd/web

enable-dev-apis:
	@tilt args -- --SECRETS_FILE_PATH="./local/k8s/secrets.dev.yaml" --VALUES_FILE_PATH="./local/k8s/values.dev.yaml"

enable-o11y:
	@tilt args -- --o11y

enable-everything:
	@tilt args -- --o11y --SECRETS_FILE_PATH="./local/k8s/secrets.dev.yaml" --VALUES_FILE_PATH="./local/k8s/values.dev.yaml"

reset-tilt-args:
	@tilt args --clear

lint:
	$(GOLANGCI_LINT) run ./... --timeout=5m

.PHONY: lf
lf: build-web lintfix
lintfix:
	$(GOLANGCI_LINT) run ./... --fix
	$(MAKE) fix-imports

fix-imports:
	@$(GCI) write --skip-generated -s standard -s default -s "prefix(github.com/saltpay/acquiring-gateway-system)" $$(find . -type f -name '*.go' -not -path "./vendor/*")

lint-api:
	docker-compose --log-level error up lint-api lint-internal-api lint-partner-api

rc: regenerate-code
regenerate-code:
	find . -iname '*_moq.go' -exec rm {} \;
	find . -iname 'api.gen.go' -exec rm {} \;
	go generate ./...

vendor:
	go mod vendor
	go mod tidy

##========= INFRASTRUCTURE-Y THINGS =========##
ut: unit-test
unit-test: unit-test-ci
unit-test-ci:
	@clear; printf '\033[3J'
	@echo "========UNIT TESTS========"
	@$(GOTEST) -shuffle=on --tags=unit  ./...
	@echo '✅  UNIT TESTS'

it: integration-test
integration-test: integration-test-ci
integration-test-ci: health-deps
	@clear; printf '\033[3J'
	@echo "========INTEGRATION TESTS========"
	@LOAD_ENV=local $(GOTEST) -count=1 --tags=integration ./...
	@echo '✅  INTEGRATION TESTS'

itd: integration-test-dev
integration-test-dev:
	@LOAD_ENV=dev go run ./cmd/util health-deps
	@LOAD_ENV=dev $(GOTEST) -count=1 --tags=integration ./...

integration-test-stoplight: health-deps
	@clear; printf '\033[3J'
	@echo "========INTEGRATION TESTS========"
	@SOLANTEQ_URL=https://stoplight.io/mocks/salt/acquiring-admin-api/34168139 \
	SETTLEMENTS_URL=https://stoplight.io/mocks/salt/acquiring-settlements-service/37278652 \
	$(GOTEST) -count=1 --tags=integration ./...
	@echo '✅  INTEGRATION TESTS'

at: acceptance-test
acceptance-test: acceptance-test-ci
acceptance-test-ci:
	@LOAD_ENV=local make health-web
	@clear; printf '\033[3J'
	@echo "========ACCEPTANCE TESTS========"
	@LOAD_ENV=local $(GOTEST) -count=1 --tags=acceptance ./blackboxtests/...
	@echo '✅  ACCEPTANCE TESTS'

atd: acceptance-test-dev
acceptance-test-dev:
	@clear; printf '\033[3J'
	@echo "========ACCEPTANCE TESTS (dev)========"
	@BASE_URL=https://acquiring-gateway-system.platform-dev.eu-west-1.salt LOAD_ENV=dev $(GOTEST) -count=1 --tags=acceptance -v ./...
	@echo '✅  ACCEPTANCE TESTS (dev)'

atd-local:
	@clear; printf '\033[3J'
	@echo "========ACCEPTANCE TESTS (local against dev APIs. remember to run make enable-dev-apis first)========"
	@BASE_URL=http://localhost:8080 \
		AG_EXTERNAL_URL=http://localhost:8080 \
		LOAD_ENV=dev $(GOTEST) -count=1 --tags=acceptance -v ./...
	@echo '✅  ACCEPTANCE TESTS (atd-local)'

etd: e2e-test-dev
e2e-test-dev:
	@clear; printf '\033[3J'
	@echo "======== E2E TESTS (dev) ========"
	@LOAD_ENV=dev \
		BASE_URL=https://acquiring-gateway-system.platform-dev.eu-west-1.salt \
		AG_EXTERNAL_URL=https://api.cloud.saltpay.dev \
 		$(GOTEST) -count=1 --tags=e2e -v ./...
	@echo '✅  E2E TESTS (dev)'

##========= DOCKER-Y THINGS =========##
hd: health-deps
health-deps:
	@LOAD_ENV=local go run ./cmd/util health-deps

hw: health-web
health-web:
	@go run ./cmd/util health-web

stop:
	@tilt down

kill:
	make stop
	# this script takes a while, so be patient...
	ctlptl delete cluster kind-kind
	docker ps -aq | xargs docker rm -f
	ctlptl docker-desktop quit
	ctlptl docker-desktop open
	@echo '💀  Killed everything. Wait for docker to come back up before running `make dev`'

build-web:
	@CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -mod vendor -o ./build/main ./cmd/web/*.go && echo "✅ built at $$(date)"

reset-postgres:
	@go run ./local/postgres/reset.go

##========= INFRASTRUCTURE-Y THINGS =========##
bump-chart-version:
	$(CHARTVERSION) bump --remote=origin --trunk=main

generate-pipeline:
	@go run ./cmd/cicdhelp

monitor-infra:
	go run ./cmd/status/argo -w

# what does this do? can we give it a better name that "docs"?
docs:
	docker run -v $(PWD):/source -w /source --rm miy4/plantuml "doc/**.puml" -o ./images

##========= TESTING PYRAMID DATA =========##

e2e_tests=$(shell find . -type f -name '*_test.go' -exec grep 'e2e' -l {} \; | xargs grep 'func Test' | wc -l)
acceptance_tests=$(shell find . -type f -name '*_test.go' -exec grep 'acceptance' -l {} \; | xargs grep 'func Test' | wc -l)
integration_tests=$(shell find . -type f -name '*_test.go' -exec grep 'integration' -l {} \; | xargs grep 'func Test' | wc -l)
integration_subtests=$(shell find . -type f -name '*_test.go' -exec grep 'integration' -l {} \; | xargs grep 't.Run' | wc -l)
unit_tests=$(shell find . -type f -name '*_test.go' -exec grep 'unit' -l {} \; | xargs grep 'func Test' | wc -l)
unit_subtests=$(shell find . -type f -name '*_test.go' -exec grep 'unit' -l {} \; | xargs grep 't.Run' | wc -l)


pyramid:
	@echo ∆∆∆ TESTING PYRAMID ∆∆∆
	@echo -- E2E_TESTS: $(e2e_tests)
	@echo --  ACCEPTANCE_TESTS_TESTS: $(acceptance_tests)
	@echo --  INTEGRATION_TESTS: $(integration_tests) with $(integration_subtests) subtests
	@echo --  UNIT_TESTS_TESTS: $(unit_tests) with $(unit_subtests) subtests


##========= Service Registration =========##

gmd-registration-dev:
	@LOAD_ENV=dev \
		PARTNER_ID="b1d3b00a-849d-490a-a874-02584ca6d256" \
		go run ./cmd/gmdregistration/cmd -service=$(service) -action=$(action)

gmd-registration-prd:
	@SOLAR_ACQUIRING_SERVICE_ID="1d744baf-f413-408f-8946-634639786c27" \
		TERMINAL_SERVICE_ID="299eb924-7293-4b79-8624-fd5404b40406" \
		WAY4_ACQUIRING_SERVICE_ID="d9bc8023-e27f-4074-9977-a6a38526df37" \
		GMDURL=https://global-merchant-database.platform-prd.eu-west-1.salt/api \
		PARTNER_ID="46444816-b719-47e2-b859-8ebecd28793a" \
		go run ./cmd/gmdregistration/cmd -service=$(service) -action=$(action)


##========= Secret management =========##
add-environment-variable:
	@go run ./cmd/envmanagement

##=== onboarding scripts
onboard-way4-dev:
	@clear; printf '\033[3J'
	@echo "======== MANUAL ONBOARD WAY4 (dev) ========"
	@LOAD_ENV=dev \
		BASE_URL=https://acquiring-gateway-system.platform-dev.eu-west-1.salt \
		AG_EXTERNAL_URL=https://api.cloud.saltpay.dev \
	    CLEANUP=false \
	    SKIP=solar \
	    SERIAL_NUMBER=$(sn) \
		$(GOTEST) -count=1 --tags=e2e -v ./blackboxtests/e2e/gmd_e2e_test.go
	@echo '✅ MANUAL ONBOARD (dev)'

onboard-solar-dev:
	@clear; printf '\033[3J'
	@echo "======== MANUAL ONBOARD SOLAR (dev) ========"
	@LOAD_ENV=dev \
		BASE_URL=https://acquiring-gateway-system.platform-dev.eu-west-1.salt \
		AG_EXTERNAL_URL=https://api.cloud.saltpay.dev \
	    CLEANUP=false \
	    SKIP=way4 \
	    SERIAL_NUMBER=$(sn) \
		$(GOTEST) -count=1 --tags=e2e -v ./blackboxtests/e2e/gmd_e2e_test.go
	@echo '✅ MANUAL ONBOARD (dev)'

fuck:
	curl \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $$GITHUB_TOKEN" \
      https://api.github.com/repos/tamj0rd2/action-testing/releases \
      -d '{"tag_name":"tags/b560050","target_commitish":"b5600502f5eac380f4228dd41396e1ac05a41488","name":"hello","body":"goodbye","draft":false,"prerelease":false,"generate_release_notes":false}'