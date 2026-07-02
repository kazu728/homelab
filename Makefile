.PHONY: build access-list
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
RSYNC_FLAGS := -av --no-perms --no-owner --no-group --omit-dir-times

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync $(RSYNC_FLAGS) -z --relative --exclude .git -e "ssh" ./flake.nix ./flake.lock ./hosts ./k8s/bootstrap $(N150_HOST):$(N150_STAGE_DIR)/
	ssh -t $(N150_HOST) "sudo mkdir -p /etc/nixos/hosts /etc/nixos/k8s/bootstrap && sudo rm -f /etc/nixos/configuration.nix && sudo rsync $(RSYNC_FLAGS) $(N150_STAGE_DIR)/flake.nix $(N150_STAGE_DIR)/flake.lock /etc/nixos/ && sudo rsync $(RSYNC_FLAGS) --delete $(N150_STAGE_DIR)/hosts/ /etc/nixos/hosts/ && sudo rsync $(RSYNC_FLAGS) --delete $(N150_STAGE_DIR)/k8s/bootstrap/ /etc/nixos/k8s/bootstrap/ && cd /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#nixos --option extra-experimental-features 'nix-command flakes'"

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
