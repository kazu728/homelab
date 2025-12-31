.PHONY: build build-n150 seal-argocd-repo
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync -avz --no-perms --no-owner --no-group --omit-dir-times --exclude .git -e "ssh" ./ $(N150_HOST):$(N150_STAGE_DIR)/
	ssh -t $(N150_HOST) "sudo rsync -av --no-perms --no-owner --no-group --omit-dir-times $(N150_STAGE_DIR)/ /etc/nixos/ && cd /etc/nixos && sudo nixos-rebuild switch"