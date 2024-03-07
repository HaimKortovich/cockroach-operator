# Copyright 2023 The Cockroach Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# This project requires the use of bazel.
# Install instuctions https://docs.bazel.build/versions/master/install.html

SHELL:=/usr/bin/env bash -O globstar

# Define path where we install binaries.
# NOTE(all): We need to use absolute paths because kubetest2 on go 1.19 does
# not support relative paths.
BINPATH := $(abspath bazel-bin)

# values used in workspace-status.sh
CLUSTER_NAME?=bazel-test
COCKROACH_DATABASE_VERSION=v21.2.3
DOCKER_IMAGE_REPOSITORY?=cockroachdb-operator
DOCKER_REGISTRY?=cockroachdb
GCP_PROJECT?=
GCP_ZONE?=
VERSION?=$(shell cat version.txt)

APP_VERSION?=v$(VERSION)
DEV_REGISTRY?=gcr.io/$(GCP_PROJECT)

# used for running e2e tests with OpenShift
PULL_SECRET?=
GCP_REGION?=
BASE_DOMAIN?=
EXTRA_KUBETEST2_PARAMS?=

#
# Unit Testing Targets
#
.PHONY: test/all
test/all: | test/apis test/pkg test/verify

.PHONY: test/apis
test/apis:
	bazel test //apis/... --test_arg=-test.v

.PHONY: test/pkg
test/pkg:
	bazel test //pkg/... --test_arg=-test.v

# This runs the all of the verify scripts and
# takes a bit of time.
.PHONY: test/verify
test/verify:
	bazel test //hack/...

.PHONY: test/lint
test/lint:
	bazel run //hack:verify-gofmt

# NODE_VERSION refers the to patch version of Kubernetes (e.g. 1.22.6)
.PHONY: test/smoketest
test/smoketest:
	@bazel run //hack/smoketest -- -dir $(PWD) -version $(NODE_VERSION)

# Run only e2e stort tests
# We can use this to only run one specific test
.PHONY: test/e2e-short
test/e2e-short:
	bazel test //e2e/... --test_arg=--test.short

# End to end testing targets
#
# k3d: use make test/e2e/k3d
# gke: use make test/e2e/gke
#
# kubetest2 binaries from the kubernetes testing team is used
# by the e2e tests.  We maintain the binaries and the binaries are
# downloaded from google storage by bazel.  See hack/bin/deps.bzl
# Once the repo releases binaries we should vendor the tag or
# download the built binaries.

# This target is used by kubetest2-tester-exec when running a k3d test
# It run k8s:k8s -type k3d which checks to see if k3d is up and running.
# Then bazel e2e testing is run.
# An example of calling this is using make test/e2e/testrunner-k3d-upgrades
test/e2e/testrunner-k3d-%: PACKAGE=$*
test/e2e/testrunner-k3d-%:
	bazel run //hack/k8s:k8s -- -type k3d
	bazel test --stamp //e2e/$(PACKAGE)/... --test_arg=-test.v --test_arg=-test.parallel=4 --test_arg=parallel=true

# Use this target to run e2e tests using a k3d k8s cluster.
# This target uses k3d to start a k8s cluster  and runs the e2e tests
# against that cluster.
#
# This is the main entrypoint for running the e2e tests on k3d.
# This target runs kubetest2 k3d that starts a k3d cluster
# Then kubetest2 tester exec is run which runs the make target
# test/e2e/testrunner-k3d.
# After the tests run the cluster is deleted.
# If you need a unique cluster name override CLUSTER_NAME.
test/e2e/k3d-%: PACKAGE=$*
test/e2e/k3d-%:
	bazel build //hack/bin/... //e2e/kubetest2-k3d/...
	PATH=$(BINPATH)/hack/bin:$(BINPATH)/e2e/kubetest2-k3d/kubetest2-k3d_/:${PATH} \
		kubetest2 k3d \
		--cluster-name=$(CLUSTER_NAME) --image rancher/k3s:v1.23.3-k3s1 --servers 3 \
		--up --down -v 10 --test=exec -- make test/e2e/testrunner-k3d-$(PACKAGE)

# This target is used by kubetest2-eks to run e2e tests.
.PHONY: test/e2e/testrunner-eks
test/e2e/testrunner-eks:
	KUBECONFIG=$(TMPDIR)/$(CLUSTER_NAME)-eks.kubeconfig.yaml $(BINPATH)/hack/bin/kubectl create -f hack/eks-storageclass.yaml
	bazel test --stamp //e2e/upgrades/...  --action_env=KUBECONFIG=$(TMPDIR)/$(CLUSTER_NAME)-eks.kubeconfig.yaml
	bazel test --stamp //e2e/create/...  --action_env=KUBECONFIG=$(TMPDIR)/$(CLUSTER_NAME)-eks.kubeconfig.yaml
	bazel test --stamp //e2e/decommission/...  --action_env=KUBECONFIG=$(TMPDIR)/$(CLUSTER_NAME)-eks.kubeconfig.yaml

# Use this target to run e2e tests with a eks cluster.
# This target uses kubetest2 to start a eks k8s cluster and runs the e2e tests
# against that cluster.
.PHONY: test/e2e/eks
test/e2e/eks:
	bazel build //hack/bin/... //e2e/kubetest2-eks/...
	PATH=${PATH}:$(BINPATH)/hack/bin:$(BINPATH)/e2e/kubetest2-eks/kubetest2-eks_/ \
	$(BINPATH)/hack/bin/kubetest2 eks --cluster-name=$(CLUSTER_NAME)  --up --down -v 10 \
		--test=exec -- make test/e2e/testrunner-eks

# This target is used by kubetest2-tester-exec when running a gke test
# k8s:k8s -type gke which checks to see if gke is up and running.
# Then bazel e2e testing is run.
# This target also installs the operator in the default namespace
# you may need to overrirde the DOCKER_IMAGE_REPOSITORY to match
# the GKEs project repo.
.PHONY: test/e2e/testrunner-gke
test/e2e/testrunner-gke:
	bazel run //hack/k8s:k8s -- -type gke
	K8S_CLUSTER=gke_$(GCP_PROJECT)_$(GCP_ZONE)_$(CLUSTER_NAME) \
	DEV_REGISTRY=$(DEV_REGISTRY) \
	# TODO this is not working because we create the cluster role binding now
	# for openshift.  We need to move this to a different target
	#bazel run --stamp --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 \
	#	//manifests:install_operator.apply
	bazel test --stamp //e2e/upgrades/...
	bazel test --stamp //e2e/create/...
	bazel test --stamp --test_arg=--pvc=true //e2e/pvcresize/...
	bazel test --stamp //e2e/decommission/...

# Use this target to run e2e tests with a gke cluster.
# This target uses kubetest2 to start a gke k8s cluster and runs the e2e tests
# against that cluster.
# This is the main entrypoint for running the e2e tests on gke.
# This target runs kubetest2 gke that starts a gke cluster
# Then kubetest2 tester exec is run which runs the make target
# test/e2e/testrunner-gke.
# After the tests run the cluster is deleted.
# If you need a unique cluster name override CLUSTER_NAME.
# You will probably want to override GCP_ZONE and GCP_PROJECT as well.
# The gcloud binary is used to start the cluster and is not installed by bazel.
# You also need gcp permission to start a cluster and upload containers to the
# projects registry.
.PHONY: test/e2e/gke
test/e2e/gke:
	bazel build //hack/bin/...
	PATH=${PATH}:$(BINPATH)/hack/bin kubetest2 gke --cluster-name=$(CLUSTER_NAME) \
		--zone=$(GCP_ZONE) --project=$(GCP_PROJECT) \
		--version latest --up --down -v 10 --ignore-gcp-ssh-key \
		--test=exec -- make test/e2e/testrunner-gke

.PHONY: test/e2e/testrunner-openshift
test/e2e/testrunner-openshift:
	bazel test --stamp //e2e/upgrades/...  --action_env=KUBECONFIG=$(HOME)/openshift-$(CLUSTER_NAME)/auth/kubeconfig
	bazel test --stamp //e2e/create/...  --action_env=KUBECONFIG=$(HOME)/openshift-$(CLUSTER_NAME)/auth/kubeconfig
	bazel test --stamp //e2e/decommission/...  --action_env=KUBECONFIG=$(HOME)/openshift-$(CLUSTER_NAME)/auth/kubeconfig

# Use this target to run e2e tests with a openshift cluster.
# This target uses kubetest2 to start a openshift cluster and runs the e2e tests
# against that cluster. A full TLD is required to creat an openshift clutser.
# This target runs kubetest2 openshift that starts a openshift cluster
# Then kubetest2 tester exec is run which runs the make target
# test/e2e/testrunner-openshift.  After the tests run the cluster is deleted.
# See the instructions in the kubetes2-openshift on running the
# provider.
.PHONY: test/e2e/openshift
test/e2e/openshift:
	bazel build //hack/bin/... //e2e/kubetest2-openshift/...
	PATH=${PATH}:$(BINPATH)/hack/bin:$(BINPATH)/e2e/kubetest2-openshift/kubetest2-openshift_/ \
	     kubetest2 openshift --cluster-name=$(CLUSTER_NAME) \
	     --gcp-project-id=$(GCP_PROJECT) \
	     --gcp-region=$(GCP_REGION) \
	     --base-domain=$(BASE_DOMAIN) \
	     --pull-secret-file=$(PULL_SECRET) \
	     $(EXTRA_KUBETEST2_PARAMS) \
	     --up --down --test=exec -- make test/e2e/testrunner-openshift

# This testrunner launchs the openshift packaging e2e test
# and requires an existing openshift cluster and the kubeconfig
# located in the usual place.
.PHONY: test/e2e/testrunner-openshift-packaging
test/e2e/testrunner-openshift-packaging: test/openshift-package
	bazel build //hack/bin:oc
	bazel test --stamp //e2e/openshift/... --cache_test_results=no \
		--action_env=KUBECONFIG=$(HOME)/openshift-$(CLUSTER_NAME)/auth/kubeconfig \
		--action_env=APP_VERSION=$(APP_VERSION) \
		--action_env=DOCKER_REGISTRY=$(DOCKER_REGISTRY)

# Run preflight checks for OpenShift. This expects a running OpenShift cluster.
# Eg. make test/preflight-<operator|bundle|marketplace>
test/preflight-%: CONTAINER=$*
test/preflight-%: release/generate-bundle
	@bazel run //hack:redhat-preflight -- $(CONTAINER)

#
# Different dev targets
#
.PHONY: dev/build
dev/build: dev/syncdeps
	bazel build //...

.PHONY: dev/fmt
dev/fmt:
	@echo +++ Running gofmt
	@bazel run //hack/bin:gofmt -- -s -w $(shell pwd)

.PHONY: dev/golangci-lint
dev/golangci-lint:
	@echo +++ Running golangci-lint
	@bazel run //hack/bin:golangci-lint run

.PHONY: dev/generate
dev/generate: | dev/update-codegen dev/update-crds

.PHONY: dev/update-codegen
dev/update-codegen:
	@bazel run //hack:update-codegen

# TODO: Be sure to update hack/verify-crds.sh if/when this changes
.PHONY: dev/update-crds
dev/update-crds:
	@bazel run //hack/bin:controller-gen \
		crd:trivialVersions=true \
		rbac:roleName=role \
		webhook \
		paths=./... \
		output:crd:artifacts:config=config/crd/bases
	@hack/boilerplaterize hack/boilerplate/boilerplate.yaml.txt config/**/*.yaml

.PHONY: dev/syncbazel
dev/syncbazel:
	@bazel run //:gazelle -- fix -external=external -go_naming_convention go_default_library
	@bazel run //hack/bin:kazel -- --cfg-path hack/build/.kazelcfg.json

.PHONY: dev/syncdeps
dev/syncdeps:
	@go mod tidy
	@bazel run //:gazelle -- update-repos \
		-from_file=go.mod \
		-to_macro=hack/build/repos.bzl%_go_dependencies \
		-build_file_generation=on \
		-build_file_proto_mode=disable \
		-prune
	@make dev/syncbazel

.PHONY: dev/up
dev/up: dev/down
	@hack/dev.sh up

.PHONY: dev/down
dev/down:
	@bazel build //hack/bin:k3d
	@hack/dev.sh down
#
# Targets that allow to install the operator on an existing cluster
#
.PHONY: k8s/apply
k8s/apply:
	K8S_CLUSTER=gke_$(GCP_PROJECT)_$(GCP_ZONE)_$(CLUSTER_NAME) \
	DEV_REGISTRY=$(DEV_REGISTRY) \
	bazel run --stamp --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 \
		//config/default:install.apply \
		--define APP_VERSION=$(APP_VERSION)

.PHONY: k8s/delete
k8s/delete:
	K8S_CLUSTER=gke_$(GCP_PROJECT)_$(GCP_ZONE)_$(CLUSTER_NAME) \
	DEV_REGISTRY=$(DEV_REGISTRY) \
	bazel run --stamp --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 \
		//config/default:install.delete \
		--define APP_VERSION=$(APP_VERSION)

#
# Release targets
#

# This target sets the version in version.txt, creates a new branch for the
# release, and generates all of the files required to cut a new release.
.PHONY: release/new
release/new:
	# TODO: verify clean, up to date master branch...
	@bazel run //hack/release -- -dir $(PWD) -version $(VERSION)

# Generate various config files, which usually contain the current operator
# version, latest CRDB version, a list of supported CRDB versions, etc.
#
# This also generates install/crds.yaml and install/operator.yaml which are
# pre-built kustomize bases used in our docs.
.PHONY: release/gen-templates
release/gen-templates:
	bazel run //hack/update_crdb_versions
	@hack/boilerplaterize hack/boilerplate/boilerplate.yaml.txt $(PWD)/crdb-versions.yaml
	bazel run //hack/crdbversions:crdbversions -- -operator-version $(APP_VERSION) -crdb-versions $(PWD)/crdb-versions.yaml -repo-root $(PWD)
	bazel run //config/crd:manifest.preview > install/crds.yaml
	bazel run //config/operator:manifest.preview > install/operator.yaml

# Generate various manifest files for OpenShift. We run this target after the
# operator version is changed. The results are committed to Git.
.PHONY: release/gen-files
release/gen-files: | release/gen-templates dev/generate
	git add . && git commit -m "Bump version to $(VERSION)"

.PHONY: release/image
release/image:
	# TODO this bazel clean is here because we need to pull the latest image from redhat registry every time
	# but this removes all caching and makes compile time for developers LONG.
	bazel clean --expunge
	DOCKER_REGISTRY=$(DOCKER_REGISTRY) \
	DOCKER_IMAGE_REPOSITORY=$(DOCKER_IMAGE_REPOSITORY) \
	APP_VERSION=$(APP_VERSION) \
	bazel run --stamp --platforms=@io_bazel_rules_go//go/toolchain:linux_amd64 \
		//:push_operator_image

#
# RedHat OpenShift targets
#

#REDHAT IMAGE BUNDLE
RH_BUNDLE_REGISTRY?=registry.connect.redhat.com/cockroachdb
RH_BUNDLE_IMAGE_REPOSITORY?=cockroachdb-operator-bundle
RH_BUNDLE_VERSION?=$(VERSION)
RH_COCKROACH_DATABASE_IMAGE=registry.connect.redhat.com/cockroachdb/cockroach:$(COCKROACH_DATABASE_VERSION)
RH_OPERATOR_IMAGE?=registry.connect.redhat.com/cockroachdb/cockroachdb-operator:$(APP_VERSION)

# Generate package bundles.
# Default options for channels if not pre-specified.
CHANNELS?=stable
DEFAULT_CHANNEL?=stable

ifneq ($(origin CHANNELS), undefined)
PKG_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
PKG_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
PKG_MAN_OPTS ?= "$(PKG_CHANNELS) $(PKG_DEFAULT_CHANNEL)"

# Build the packagemanifests
.PHONY: release/generate-bundle
release/generate-bundle:
	bazel run //hack:bundle -- $(RH_BUNDLE_VERSION) $(RH_OPERATOR_IMAGE) $(PKG_MAN_OPTS) $(RH_COCKROACH_DATABASE_IMAGE)

.PHONY: release/publish-operator
publish-operator:
	./build/release/teamcity-publish-release.sh

.PHONY: release/publish-operator-openshift
publish-operator-openshift:
	./build/release/teamcity-publish-openshift.sh

.PHONY: release/publish-openshift-bundle
release/publish-openshift-bundle:
	./build/release/teamcity-publish-openshift-bundle.sh


# --------------------------------------------------------------
# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.1

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
# This variable is used to construct full image tags for bundle and catalog images.
#
# For example, running 'make bundle-build bundle-push catalog-build catalog-push' will build and push both
# topmanage.com/src-bundle:$VERSION and topmanage.com/src-catalog:$VERSION.
IMAGE_TAG_BASE ?= topmanage.com/src

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Set the Operator SDK version to use. By default, what is installed on the system is used.
# This is useful for CI or a project to utilize a specific version of the operator-sdk toolkit.
OPERATOR_SDK_VERSION ?= unknown

# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.26.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test ./... -coverprofile cover.out

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish built the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64 ). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: test ## Build docker image with the manager.
	docker build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: test ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- docker buildx create --name project-v3-builder
	docker buildx use project-v3-builder
	- docker buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- docker buildx rm project-v3-builder
	rm Dockerfile.cross

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest

## Tool Versions
KUSTOMIZE_VERSION ?= v4.5.7
CONTROLLER_TOOLS_VERSION ?= v0.11.1

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || { curl -Ss $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary. If wrong version is installed, it will be overwritten.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

.PHONY: operator-sdk
OPERATOR_SDK ?= $(LOCALBIN)/operator-sdk
operator-sdk: ## Download operator-sdk locally if necessary.
ifeq (,$(wildcard $(OPERATOR_SDK)))
ifeq (, $(shell which operator-sdk 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPERATOR_SDK)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPERATOR_SDK) https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$${OS}_$${ARCH} ;\
	chmod +x $(OPERATOR_SDK) ;\
	}
else
OPERATOR_SDK = $(shell which operator-sdk)
endif
endif

.PHONY: bundle
bundle: manifests kustomize operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle $(BUNDLE_GEN_FLAGS)
	$(OPERATOR_SDK) bundle validate ./bundle

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: opm
OPM = ./bin/opm
opm: ## Download opm locally if necessary.
ifeq (,$(wildcard $(OPM)))
ifeq (,$(shell which opm 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPM)) ;\
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(OPM) https://github.com/operator-framework/operator-registry/releases/download/v1.23.0/$${OS}-$${ARCH}-opm ;\
	chmod +x $(OPM) ;\
	}
else
OPM = $(shell which opm)
endif
endif

# A comma-separated list of bundle images (e.g. make catalog-build BUNDLE_IMGS=example.com/operator-bundle:v0.1.0,example.com/operator-bundle:v0.2.0).
# These images MUST exist in a registry and be pull-able.
BUNDLE_IMGS ?= $(BUNDLE_IMG)

# The image tag given to the resulting catalog image (e.g. make catalog-build CATALOG_IMG=example.com/operator-catalog:v0.2.0).
CATALOG_IMG ?= $(IMAGE_TAG_BASE)-catalog:v$(VERSION)

# Set CATALOG_BASE_IMG to an existing catalog image tag to add $BUNDLE_IMGS to that image.
ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

# Build a catalog image by adding bundle images to an empty catalog using the operator package manager tool, 'opm'.
# This recipe invokes 'opm' in 'semver' bundle add mode. For more information on add modes, see:
# https://github.com/operator-framework/community-operators/blob/7f1438c/docs/packaging-operator.md#updating-your-existing-operator
.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

# Push the catalog image.
.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

HELMIFY ?= $(LOCALBIN)/helmify

.PHONY: helmify
helmify: $(HELMIFY) ## Download helmify locally if necessary.
$(HELMIFY): $(LOCALBIN)
	test -s $(LOCALBIN)/helmify || GOBIN=$(LOCALBIN) go install github.com/arttor/helmify/cmd/helmify@latest

helm: manifests kustomize helmify
	$(KUSTOMIZE) build config/default | $(HELMIFY) -crd-dir cockroach-operator && mv cockroach-operator/ chart/
