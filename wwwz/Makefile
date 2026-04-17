# wwwz - wiz report generator
# airgapped-friendly helm chart shipment

NAME    := wwwz
VERSION := 0.1.0
DIST    := dist

IMAGE       := $(NAME):$(VERSION)
IMAGE_LATEST:= $(NAME):latest
IMAGE_TAR   := $(DIST)/$(NAME)-$(VERSION).tar.gz
CHART_TGZ   := $(DIST)/$(NAME)-$(VERSION).tgz
BUNDLE      := $(DIST)/$(NAME)-bundle-$(VERSION).tar.gz

.DEFAULT_GOAL := help

.PHONY: help build build-airgapped push save package bundle lint template test-local clean

help: ## show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## build docker image tagged $(IMAGE) and :latest
	docker build -f docker/Dockerfile -t $(IMAGE) -t $(IMAGE_LATEST) .

build-airgapped: ## build with internal base registry (REGISTRY=registry.example.com)
	@if [ -z "$(REGISTRY)" ]; then echo "REGISTRY is required, e.g. make build-airgapped REGISTRY=registry.example.com"; exit 1; fi
	docker build -f docker/Dockerfile \
		--build-arg BASE_REGISTRY=$(REGISTRY) \
		-t $(IMAGE) -t $(IMAGE_LATEST) .

push: ## tag and push to $(REGISTRY)/wwwz:$(VERSION) and :latest
	@if [ -z "$(REGISTRY)" ]; then echo "REGISTRY is required, e.g. make push REGISTRY=registry.example.com"; exit 1; fi
	docker tag $(IMAGE) $(REGISTRY)/$(IMAGE)
	docker tag $(IMAGE_LATEST) $(REGISTRY)/$(IMAGE_LATEST)
	docker push $(REGISTRY)/$(IMAGE)
	docker push $(REGISTRY)/$(IMAGE_LATEST)

save: ## save image as $(IMAGE_TAR) for airgapped transfer
	@mkdir -p $(DIST)
	docker save $(IMAGE) | gzip > $(IMAGE_TAR)
	@echo "saved: $(IMAGE_TAR)"

package: ## helm package chart/ into dist/
	@mkdir -p $(DIST)
	helm package chart/ -d $(DIST)
	@echo "packaged: $(CHART_TGZ)"

bundle: save package ## bundle image + chart + readme into $(BUNDLE)
	@mkdir -p $(DIST)
	@tmp=$$(mktemp -d); \
	cp $(IMAGE_TAR) $$tmp/; \
	cp $(CHART_TGZ) $$tmp/; \
	printf '%s\n' \
		'# wwwz airgapped bundle $(VERSION)' \
		'' \
		'contents:' \
		'- $(NAME)-$(VERSION).tar.gz  docker image (load with docker load)' \
		'- $(NAME)-$(VERSION).tgz     helm chart' \
		'' \
		'quick install (airgapped env):' \
		'' \
		'  # 1. load the image and push to internal registry' \
		'  docker load < $(NAME)-$(VERSION).tar.gz' \
		'  docker tag $(IMAGE) registry.example.com/$(IMAGE)' \
		'  docker push registry.example.com/$(IMAGE)' \
		'' \
		'  # 2. configure vault with wiz credentials at secret/wiz/api' \
		'  #    keys: client_id, client_secret, teams_webhook_url' \
		'' \
		'  # 3. install the chart' \
		'  helm install $(NAME) ./$(NAME)-$(VERSION).tgz \' \
		'    -n $(NAME) --create-namespace \' \
		'    -f your-values.yaml' \
		'' \
		'see main README.md for full configuration options.' \
		> $$tmp/README.md; \
	tar -czf $(BUNDLE) -C $$tmp .; \
	rm -rf $$tmp
	@echo "bundle: $(BUNDLE)"

lint: ## helm lint chart/
	helm lint chart/

template: ## helm template preview
	helm template test chart/

test-local: ## run wiz_report.py locally (requires src/.env)
	@if [ ! -f src/.env ]; then echo "missing src/.env - copy from src/.env.example"; exit 1; fi
	cd src && set -a && . ./.env && set +a && python3 wiz_report.py

clean: ## remove dist/ and generated artifacts
	rm -rf $(DIST) output
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type f -name '*.pyc' -delete
