.PHONY: help image-status image-verify image-load image-all

MANIFEST ?= artifacts/build-manifest.json
IMAGE_TOOL := ./image-artifact-tool.sh

help:
	@echo "Available targets:"
	@echo "  make image-status   # Show artifact and image status"
	@echo "  make image-verify   # Verify checksum + image/tag integrity"
	@echo "  make image-load     # Load tar into Docker and apply tags"
	@echo "  make image-all      # status -> verify -> load -> verify"
	@echo ""
	@echo "Override manifest path:"
	@echo "  make image-status MANIFEST=artifacts/build-manifest.json"

image-status:
	@MANIFEST_PATH="$(MANIFEST)" $(IMAGE_TOOL) status

image-verify:
	@MANIFEST_PATH="$(MANIFEST)" $(IMAGE_TOOL) verify

image-load:
	@MANIFEST_PATH="$(MANIFEST)" $(IMAGE_TOOL) load

image-all:
	@MANIFEST_PATH="$(MANIFEST)" $(IMAGE_TOOL) all
