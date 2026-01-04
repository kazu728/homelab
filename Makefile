.PHONY: build build-n150 seal-argocd-repo
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
ARGOCD_REPO_KEY ?= ~/.ssh/argocd_homelab
ARGOCD_REPO_SECRET ?= k8s/bootstrap/40-argocd-repo-sealedsecret.yaml

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync -avz --no-perms --no-owner --no-group --omit-dir-times --exclude .git -e "ssh" ./ $(N150_HOST):$(N150_STAGE_DIR)/
	ssh -t $(N150_HOST) "sudo rsync -av --no-perms --no-owner --no-group --omit-dir-times $(N150_STAGE_DIR)/ /etc/nixos/ && cd /etc/nixos && sudo nixos-rebuild switch"

seal-argocd-repo:
	ssh $(N150_HOST) "printf 'y\n' | ssh-keygen -t ed25519 -f $(ARGOCD_REPO_KEY) -C 'argocd@$(N150_HOST)' -N ''"
	ssh $(N150_HOST) "kubectl -n argo-cd create secret generic repo-kazu728-homelab \
	  --from-literal=type=git \
	  --from-literal=url=git@github.com:kazu728/homelab.git \
	  --from-file=sshPrivateKey=$(ARGOCD_REPO_KEY) \
	  --dry-run=client -o yaml \
	| kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
	| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
	> /tmp/40-argocd-repo-sealedsecret.yaml"
	scp $(N150_HOST):/tmp/40-argocd-repo-sealedsecret.yaml $(ARGOCD_REPO_SECRET)
	ssh -t $(N150_HOST) "sudo mv /tmp/40-argocd-repo-sealedsecret.yaml /etc/nixos/k8s/bootstrap/40-argocd-repo-sealedsecret.yaml"
