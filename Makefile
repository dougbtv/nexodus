.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#
# If you want to see the full commands, run:
#   NOISY_BUILD=y make
#
ifeq ($(NOISY_BUILD),)
    ECHO_PREFIX=@
    CMD_PREFIX=@
else
    ECHO_PREFIX=@\#
    CMD_PREFIX=
endif

NEXODUS_VERSION?=$(shell date +%Y.%m.%d)
NEXODUS_RELEASE?=$(shell git describe --always)
NEXODUS_LDFLAGS?=-X main.Version=$(NEXODUS_VERSION)-$(NEXODUS_RELEASE)

# Crunchy DB operator does not work well on arm64, use an different overlay to work around it.
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),arm64)
	OVERLAY?=arm64
else
	OVERLAY?=dev
endif

##@ All

.PHONY: all
all: go-lint yaml-lint md-lint ui-lint nexd nexctl ## Run linters and build nexd

##@ Binaries

.PHONY: nexd
nexd: dist/nexd dist/nexd-linux-arm dist/nexd-linux-amd64 dist/nexd-darwin-amd64 dist/nexd-darwin-arm64 dist/nexd-windows-amd64 ## Build the nexd binary for all architectures

.PHONY: nexctl
nexctl: dist/nexctl dist/nexctl-linux-arm dist/nexctl-linux-amd64 dist/nexctl-darwin-amd64 dist/nexctl-darwin-arm64 dist/nexctl-windows-amd64 ## Build the nexctl binary for all architectures

COMMON_DEPS=$(wildcard ./internal/**/*.go) go.sum go.mod

NEXD_DEPS=$(COMMON_DEPS) $(wildcard cmd/nexd/*.go)

NEXCTL_DEPS=$(COMMON_DEPS) $(wildcard cmd/nexctl/*.go)

APISERVER_DEPS=$(COMMON_DEPS) $(wildcard cmd/apiserver/*.go)

TAG=$(shell git rev-parse HEAD)

dist:
	$(CMD_PREFIX) mkdir -p $@

dist/nexd: $(NEXD_DEPS) | dist
	$(ECHO_PREFIX) printf "  %-12s $@\n" "[GO BUILD]"
	$(CMD_PREFIX) CGO_ENABLED=0 go build -ldflags="$(NEXODUS_LDFLAGS)" -o $@ ./cmd/nexd

dist/nexctl: $(NEXCTL_DEPS) | dist
	$(ECHO_PREFIX) printf "  %-12s $@\n" "[GO BUILD]"
	$(CMD_PREFIX) CGO_ENABLED=0 go build -ldflags="$(NEXODUS_LDFLAGS)" -o $@ ./cmd/nexctl

dist/nexd-%: $(NEXD_DEPS) | dist
	$(ECHO_PREFIX) printf "  %-12s $@\n" "[GO BUILD]"
	$(CMD_PREFIX) CGO_ENABLED=0 GOOS=$(word 2,$(subst -, ,$(basename $@))) GOARCH=$(word 3,$(subst -, ,$(basename $@))) \
		go build -ldflags="$(NEXODUS_LDFLAGS)" -o $@ ./cmd/nexd

dist/nexctl-%: $(NEXCTL_DEPS) | dist
	$(ECHO_PREFIX) printf "  %-12s $@\n" "[GO BUILD]"
	$(CMD_PREFIX) CGO_ENABLED=0 GOOS=$(word 2,$(subst -, ,$(basename $@))) GOARCH=$(word 3,$(subst -, ,$(basename $@))) \
		go build -ldflags="$(NEXODUS_LDFLAGS)" -o $@ ./cmd/nexctl

.PHONY: clean
clean: ## clean built binaries
	rm -rf dist

##@ Development

.PHONY: go-lint
go-lint: $(NEXD_DEPS) $(NEXCTL_DEPS) $(APISERVER_DEPS) ## Lint the go code
	@if ! which golangci-lint >/dev/null 2>&1; then \
		echo "Please install golangci-lint." ; \
		echo "See: https://golangci-lint.run/usage/install/#local-installation" ; \
		exit 1 ; \
	fi
	$(ECHO_PREFIX) printf "  %-12s ./...\n" "[GO LINT]"
	$(CMD_PREFIX) golangci-lint run ./...

.PHONY: yaml-lint
yaml-lint: ## Lint the yaml files
	@if ! which yamllint >/dev/null 2>&1; then \
		echo "Please install yamllint." ; \
		echo "See: https://yamllint.readthedocs.io/en/stable/quickstart.html" ; \
		exit 1 ; \
	fi
	$(ECHO_PREFIX) printf "  %-12s ./...\n" "[YAML LINT]"
	$(CMD_PREFIX) yamllint -c .yamllint.yaml deploy --strict

.PHONY: md-lint
md-lint: ## Lint markdown files
	$(ECHO_PREFIX) printf "  %-12s ./...\n" "[MD LINT]"
	$(CMD_PREFIX) docker run -v $(CURDIR):/workdir docker.io/davidanson/markdownlint-cli2:v0.6.0 "**/*.md" "#ui/node_modules" > /dev/null

.PHONY: ui-lint
ui-lint: ## Lint the UI source
	$(ECHO_PREFIX) printf "  %-12s ./...\n" "[UI LINT]"
	$(CMD_PREFIX) docker run -v $(CURDIR):/workdir tmknom/prettier --check /workdir/ui/src/ >/dev/null

.PHONY: gen-docs
gen-docs: ## Generate API docs
	swag init -g ./cmd/apiserver/main.go -o ./internal/docs

.PHONY: e2e
e2e: e2eprereqs test-images ## Run e2e tests
	go test -v --tags=integration ./integration-tests/...

.PHONY: e2e-podman
e2e-podman: ## Run e2e tests on podman
	go test -c -v --tags=integration ./integration-tests/...
	sudo NEXODUS_TEST_PODMAN=1 TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED=true ./integration-tests.test -test.v

.PHONY: test
test: ## Run unit tests
	go test -v ./...

NEXODUS_LOCAL_IP:=`go run ./hack/localip`
.PHONY: run-test-container
TEST_CONTAINER_DISTRO?=ubuntu
run-test-container: ## Run docker container that you can run nexodus in
	@docker build -f Containerfile.test -t quay.io/nexodus/test:$(TEST_CONTAINER_DISTRO) --target $(TEST_CONTAINER_DISTRO) .
	@docker run --rm -it --network bridge \
		--cap-add SYS_MODULE \
		--cap-add NET_ADMIN \
		--cap-add NET_RAW \
		--add-host apex.local:$(NEXODUS_LOCAL_IP) \
		--add-host api.apex.local:$(NEXODUS_LOCAL_IP) \
		--add-host auth.apex.local:$(NEXODUS_LOCAL_IP) \
		--mount type=bind,source=$(shell pwd)/.certs,target=/.certs,readonly \
		quay.io/nexodus/test:$(TEST_CONTAINER_DISTRO) /update-ca.sh

.PHONY: run-sql-apiserver
run-sql-apiserver: ## runs a command line SQL client to interact with the apiserver database
ifeq ($(OVERLAY),dev)
	@kubectl exec -it -n apex \
		$(shell kubectl get pods -l postgres-operator.crunchydata.com/role=master -o name) \
		-c database -- psql apiserver
else ifeq ($(OVERLAY),arm64)
	@kubectl exec -it -n apex svc/postgres -c postgres -- psql -U apiserver apiserver
else ifeq ($(OVERLAY),cockroach)
	@kubectl exec -it -n apex svc/cockroachdb -- cockroach sql --insecure --user apiserver --database apiserver
endif


##@ Container Images

.PHONY: test-images
test-images: dist/nexd dist/nexctl ## Create test images for e2e
	docker build -f Containerfile.test -t quay.io/nexodus/test:alpine --target alpine .
	docker build -f Containerfile.test -t quay.io/nexodus/test:fedora --target fedora .
	docker build -f Containerfile.test -t quay.io/nexodus/test:ubuntu --target ubuntu .

.PHONY: e2eprereqs
e2eprereqs:
	@if [ -z "$(shell which kind)" ]; then \
		echo "Please install kind and then start the kind dev environment." ; \
		echo "https://kind.sigs.k8s.io/" ; \
		echo "  $$ make run-on-kind" ; \
		exit 1 ; \
	fi
	@if [ -z "$(findstring nexodus-dev,$(shell kind get clusters))" ]; then \
		echo "Please start the kind dev environment." ; \
		echo "  $$ make run-on-kind" ; \
		exit 1 ; \
	fi

.PHONY: image-frontend
image-frontend:
	docker build -f Containerfile.frontend -t quay.io/nexodus/frontend:$(TAG) .
	docker tag quay.io/nexodus/frontend:$(TAG) quay.io/nexodus/frontend:latest

.PHONY: image-apiserver
image-apiserver:
	docker build -f Containerfile.apiserver -t quay.io/nexodus/apiserver:$(TAG) .
	docker tag quay.io/nexodus/apiserver:$(TAG) quay.io/nexodus/apiserver:latest

.PHONY: image-nexd ## Build the nexodus agent image
image-nexd:
	docker build -f Containerfile.nexd -t quay.io/nexodus/nexd:$(TAG) .
	docker tag quay.io/nexodus/nexd:$(TAG) quay.io/nexodus/nexd:latest

.PHONY: image-ipam ## Build the IPAM image
image-ipam:
	docker build -f Containerfile.ipam -t quay.io/apex/go-ipam:$(TAG) .
	docker tag quay.io/apex/go-ipam:$(TAG) quay.io/apex/go-ipam:latest

.PHONY: images
images: image-frontend image-apiserver image-ipam ## Create container images

##@ Kubernetes - kind dev environment

.PHONY: run-on-kind
run-on-kind: setup-kind deploy-operators images load-images deploy cacerts ## Setup a kind cluster and deploy nexodus on it

.PHONY: teardown
teardown: ## Teardown the kind cluster
	@kind delete cluster --name nexodus-dev

.PHONY: setup-kind
setup-kind: teardown ## Create a kind cluster with ingress enabled, but don't install nexodus.
	@kind create cluster --config ./deploy/kind.yaml
	@kubectl cluster-info --context kind-nexodus-dev
	@kubectl apply -f ./deploy/kind-ingress.yaml

.PHONY: deploy-nexodus-agent ## Deply the nexodus agent in the kind cluster
deploy-nexodus-agent: image-nexd
	@kind load --name nexodus-dev docker-image quay.io/nexodus/nexd:latest
	@cp deploy/apex-client/overlays/dev/kustomization.yaml.sample deploy/apex-client/overlays/dev/kustomization.yaml
	@sed -i -e "s/<APEX_CONTROLLER_IP>/$(NEXODUS_LOCAL_IP)/" deploy/apex-client/overlays/dev/kustomization.yaml
	@sed -i -e "s/<APEX_CONTROLLER_CERT>/$(shell kubectl get secret -n apex apex-ca-key-pair -o json | jq -r '.data."ca.crt"')/" deploy/apex-client/overlays/dev/kustomization.yaml
	@kubectl apply -k ./deploy/apex-client/overlays/dev

##@ Kubernetes - work with an existing cluster (kind dev env or another one)

.PHONY: deploy-operators
deploy-operators: deploy-certmanager deploy-pgo  ## Deploy all operators and wait for readiness

.PHONY: deploy-certmanager
deploy-certmanager: # Deploy cert-manager
	@kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.1/cert-manager.yaml

CRUNCHY_REVISION?=f1766db0b50ad2ae8ff35a599a16e11eefbd9f9c
.PHONY: deploy-pgo
deploy-pgo: # Deploy crunchy-data postgres operator
	@kubectl apply -k https://github.com/CrunchyData/postgres-operator-examples/kustomize/install/namespace?ref=$(CRUNCHY_REVISION)
	@kubectl apply --server-side -k https://github.com/CrunchyData/postgres-operator-examples/kustomize/install/default?ref=$(CRUNCHY_REVISION)

.PHONY: deploy-cockroach-operator
deploy-cockroach-operator: ## Deploy cockroach operator
	@kubectl apply -k https://github.com/CrunchyData/postgres-operator-examples/kustomize/install/namespace
	@kubectl apply -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.10.0/install/crds.yaml
	@kubectl apply -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.10.0/install/operator.yaml
	@kubectl wait --for=condition=Available --timeout=5m -n cockroach-operator-system deploy/cockroach-operator-manager
	@./hack/wait-for-cockroach-operator-ready.sh

.PHONY: use-cockroach
use-cockroach: deploy-cockroach-operator ## Recreate the database with a Cockroach based server
	@OVERLAY=cockroach make recreate-db

.PHONY: use-crunchy
use-crunchy: ## Recreate the database with a Crunchy based postgres server
	@OVERLAY=dev make recreate-db

.PHONY: use-postgres
use-postgres: ## Recreate the database with a simple Postgres server
	@OVERLAY=arm64 make recreate-db

.PHONY: wait-for-readiness
wait-for-readiness: # Wait for operators to be installed
	@kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=5m
	@kubectl rollout status -n cert-manager deploy/cert-manager --timeout=5m
	@kubectl rollout status -n cert-manager deploy/cert-manager-webhook --timeout=5m
	@kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=5m
	@kubectl wait --for=condition=Ready pods --all -n postgres-operator --timeout=5m

.PHONY: deploy
deploy: wait-for-readiness ## Deploy a development nexodus stack onto a kubernetes cluster
	@kubectl create namespace apex
	@kubectl apply -k ./deploy/apex/overlays/$(OVERLAY)
	@OVERLAY=$(OVERLAY) make init-db
	@kubectl wait --for=condition=Ready pods --all -n apex -l app.kubernetes.io/part-of=apex --timeout=15m

.PHONY: undeploy
undeploy: ## Remove the nexodus stack from a kubernetes cluster
	@kubectl delete namespace apex

.PHONY: load-images
load-images: ## Load images onto kind
	@kind load --name nexodus-dev docker-image quay.io/nexodus/apiserver:latest
	@kind load --name nexodus-dev docker-image quay.io/nexodus/frontend:latest
	@kind load --name nexodus-dev docker-image quay.io/apex/go-ipam:latest

.PHONY: redeploy
redeploy: images load-images ## Redeploy nexodus after images changes
	@kubectl rollout restart deploy/apiserver -n apex
	@kubectl rollout restart deploy/frontend -n apex

.PHONY: init-db
init-db:
# wait for the DB to be up, then restart the services that use it.
ifeq ($(OVERLAY),dev)
	@kubectl wait -n apex postgresclusters/database  --timeout=15m --for=jsonpath='{.status.instances[0].readyReplicas}'=1
else ifeq ($(OVERLAY),arm64)
	@kubectl wait -n apex statefulsets/postgres --timeout=15m --for=jsonpath='{.status.readyReplicas}'=1
else ifeq ($(OVERLAY),cockroach)
	@make deploy-cockroach-operator
	@kubectl -n apex wait --for=condition=Initialized crdbcluster/cockroachdb --timeout=5m
	@kubectl -n apex rollout status statefulsets/cockroachdb --timeout=5m
	@kubectl -n apex exec -it cockroachdb-0 \
	  	-- ./cockroach sql \
		--insecure \
		--certs-dir=/cockroach/cockroach-certs \
		--host=cockroachdb-public \
		--execute "\
			CREATE DATABASE IF NOT EXISTS ipam;\
			CREATE USER IF NOT EXISTS ipam;\
			GRANT ALL ON DATABASE ipam TO ipam;\
			CREATE DATABASE IF NOT EXISTS apiserver;\
			CREATE USER IF NOT EXISTS apiserver;\
			GRANT ALL ON DATABASE apiserver TO apiserver;\
			CREATE DATABASE IF NOT EXISTS keycloak;\
			CREATE USER IF NOT EXISTS keycloak;\
			GRANT ALL ON DATABASE keycloak TO keycloak;\
			"
endif
	@kubectl rollout restart deploy/apiserver -n apex
	@kubectl rollout restart deploy/ipam -n apex
	@kubectl -n apex rollout status deploy/apiserver --timeout=5m
	@kubectl -n apex rollout status deploy/ipam --timeout=5m

.PHONY: recreate-db
recreate-db: ## Delete and bring up a new apex database

	@kubectl delete -n apex postgrescluster/database 2> /dev/null || true
	@kubectl wait --for=delete -n apex postgrescluster/database
	@kubectl delete -n apex statefulsets/postgres persistentvolumeclaims/postgres-disk-postgres-0 2> /dev/null || true
	@kubectl wait --for=delete -n apex persistentvolumeclaims/postgres-disk-postgres-0
	@kubectl delete -n apex crdbclusters/cockroachdb 2> /dev/null || true
	@kubectl wait --for=delete -n apex --all pods -l app.kubernetes.io/name=cockroachdb --timeout=2m
	@kubectl delete -n apex persistentvolumeclaims/datadir-cockroachdb-0 persistentvolumeclaims/datadir-cockroachdb-1 persistentvolumeclaims/datadir-cockroachdb-2 2> /dev/null || true
	@kubectl wait --for=delete -n apex persistentvolumeclaims/datadir-cockroachdb-0
	@kubectl wait --for=delete -n apex persistentvolumeclaims/datadir-cockroachdb-1
	@kubectl wait --for=delete -n apex persistentvolumeclaims/datadir-cockroachdb-2

	@kubectl apply -k ./deploy/apex/overlays/$(OVERLAY) | grep -v unchanged
	@OVERLAY=$(OVERLAY) make init-db
	@kubectl wait --for=condition=Ready pods --all -n apex -l app.kubernetes.io/part-of=apex --timeout=15m

.PHONY: cacerts
cacerts: ## Install the Self-Signed CA Certificate
	@mkdir -p $(CURDIR)/.certs
	@kubectl get secret -n apex apex-ca-key-pair -o json | jq -r '.data."ca.crt"' | base64 -d > $(CURDIR)/.certs/rootCA.pem
	@CAROOT=$(CURDIR)/.certs mkcert -install

##@ Packaging

dist/rpm:
	$(CMD_PREFIX) mkdir -p dist/rpm

.PHONY: image-mock
image-mock:
	docker build -f Containerfile.mock -t quay.io/nexodus/mock:$(TAG) .
	docker tag quay.io/nexodus/mock:$(TAG) quay.io/nexodus/mock:latest

MOCK_ROOT?=fedora-37-x86_64
SRPM_DISTRO?=fc37

.PHONY: srpm
srpm: dist/rpm image-mock manpages ## Build a source RPM
	go mod vendor
	rm -rf dist/rpm/nexodus-${NEXODUS_RELEASE}
	rm -f dist/rpm/nexodus-${NEXODUS_RELEASE}.tar.gz
	git archive --format=tar.gz -o dist/rpm/nexodus-${NEXODUS_RELEASE}.tar.gz --prefix=nexodus-${NEXODUS_RELEASE}/ ${NEXODUS_RELEASE}
	cd dist/rpm && tar xzf nexodus-${NEXODUS_RELEASE}.tar.gz
	mv vendor dist/rpm/nexodus-${NEXODUS_RELEASE}/.
	mkdir -p dist/rpm/nexodus-${NEXODUS_RELEASE}/contrib/man
	cp -r contrib/man/* dist/rpm/nexodus-${NEXODUS_RELEASE}/contrib/man/.
	cd dist/rpm && tar czf nexodus-${NEXODUS_RELEASE}.tar.gz nexodus-${NEXODUS_RELEASE} && rm -rf nexodus-${NEXODUS_RELEASE}
	cp contrib/rpm/nexodus.spec.in contrib/rpm/nexodus.spec
	sed -i -e "s/##NEXODUS_COMMIT##/${NEXODUS_RELEASE}/" contrib/rpm/nexodus.spec
	docker run --name mock --rm --privileged=true -v $(CURDIR):/nexodus quay.io/nexodus/mock:latest \
		mock --buildsrpm -D "_commit ${NEXODUS_RELEASE}" --resultdir=/nexodus/dist/rpm/mock --no-clean --no-cleanup-after \
		--spec /nexodus/contrib/rpm/nexodus.spec --sources /nexodus/dist/rpm/ --root ${MOCK_ROOT}
	rm -f dist/rpm/nexodus-${NEXODUS_RELEASE}.tar.gz

.PHONY: rpm
rpm: srpm ## Build an RPM
	docker run --name mock --rm --privileged=true -v $(CURDIR):/nexodus quay.io/nexodus/mock:latest \
		mock --rebuild --without check --resultdir=/nexodus/dist/rpm/mock --root ${MOCK_ROOT} --no-clean --no-cleanup-after \
		/nexodus/$(wildcard dist/rpm/mock/nexodus-0-0.1.$(shell date --utc +%Y%m%d)git$(NEXODUS_RELEASE).$(SRPM_DISTRO).src.rpm)

##@ Manpage Generation

contrib/man:
	$(CMD_PREFIX) mkdir -p contrib/man

.PHONY: manpages
manpages: contrib/man dist/nexd dist/nexctl image-mock ## Generate manpages in ./contrib/man
	dist/nexd -h | docker run -i --rm --name txt2man quay.io/nexodus/mock:latest txt2man -t nexd | gzip > contrib/man/nexd.8.gz
	dist/nexctl -h | docker run -i --rm --name txt2man quay.io/nexodus/mock:latest txt2man -t nexctl | gzip > contrib/man/nexctl.8.gz

# Nothing to see here
.PHONY: cat
cat:
	$(CMD_PREFIX) docker run -it --rm --name nyancat 06kellyjac/nyancat
