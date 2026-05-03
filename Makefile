.PHONY: build seal-argocd-repo access-list
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
ARGOCD_REPO_KEY ?= ~/.ssh/argocd_homelab
HOMELAB_HOST ?=

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync -avz --relative --no-perms --no-owner --no-group --omit-dir-times --exclude .git -e "ssh" ./configuration.nix ./hosts ./k8s/bootstrap $(N150_HOST):$(N150_STAGE_DIR)/
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
	scp $(N150_HOST):/tmp/40-argocd-repo-sealedsecret.yaml k8s/bootstrap/40-argocd-repo-sealedsecret.yaml
	ssh -t $(N150_HOST) "sudo mv /tmp/40-argocd-repo-sealedsecret.yaml /etc/nixos/k8s/bootstrap/40-argocd-repo-sealedsecret.yaml"

access-list:
	@host="$${HOMELAB_HOST:-$$(ssh $(N150_HOST) 'tailscale status --json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"; \
	ssh -o LogLevel=ERROR -t $(N150_HOST) "sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml HOMELAB_ACCESS_HOST='$$host' sh -c 'set -eu; \
	grafana_user=\$$(kubectl -n observability get secret grafana -o jsonpath=\"{.data.admin-user}\" | base64 --decode); \
	grafana_pass=\$$(kubectl -n observability get secret grafana -o jsonpath=\"{.data.admin-password}\" | base64 --decode); \
	argo_pass_base64=\$$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" 2>/dev/null || kubectl -n argo-cd get secret argo-cd-initial-admin-secret -o jsonpath=\"{.data.password}\" 2>/dev/null); \
	argo_pass=\$$(printf \"%s\" \"\$$argo_pass_base64\" | base64 --decode); \
	grafana_pod=\$$(kubectl -n observability get pod -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana -o jsonpath=\"{.items[0].metadata.name}\"); \
	kubectl -n observability exec \"\$$grafana_pod\" -c grafana -- grafana cli admin reset-admin-password \"\$$grafana_pass\" >/dev/null 2>&1 || kubectl -n observability exec \"\$$grafana_pod\" -c grafana -- grafana-cli admin reset-admin-password \"\$$grafana_pass\" >/dev/null; \
	printf \"Homelab access endpoints:\\n  Grafana: https://%s/\\n  Argo CD: https://%s:8443/\\n\\nCredentials:\\n  Grafana:\\n    user: %s\\n    pass: %s\\n  Argo CD:\\n    user: admin\\n    pass: %s\\n\" \"\$$HOMELAB_ACCESS_HOST\" \"\$$HOMELAB_ACCESS_HOST\" \"\$$grafana_user\" \"\$$grafana_pass\" \"\$$argo_pass\"'"
