.PHONY: build seal-nats-token access-list
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
HOMELAB_HOST ?=
NATS_SERVER_SECRET_FILE ?= k8s/argocd/platform/nats-auth-sealedsecret.yaml
NATS_CLIENT_SECRET_FILE ?= k8s/workloads/nats-client-auth-sealedsecret.yaml

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync -avz --relative --no-perms --no-owner --no-group --omit-dir-times --exclude .git -e "ssh" ./configuration.nix ./hosts ./k8s/bootstrap $(N150_HOST):$(N150_STAGE_DIR)/
	ssh -t $(N150_HOST) "sudo rsync -av --no-perms --no-owner --no-group --omit-dir-times $(N150_STAGE_DIR)/ /etc/nixos/ && sudo rsync -av --delete --no-perms --no-owner --no-group --omit-dir-times $(N150_STAGE_DIR)/k8s/bootstrap/ /etc/nixos/k8s/bootstrap/ && cd /etc/nixos && sudo nixos-rebuild switch"

seal-nats-token:
	@mkdir -p "$(dir $(NATS_SERVER_SECRET_FILE))" "$(dir $(NATS_CLIENT_SECRET_FILE))"
	@token="$${NATS_TOKEN:-$$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')}"; \
	printf "%s" "$$token" | ssh $(N150_HOST) "cat > /tmp/nats-token"; \
	ssh $(N150_HOST) "kubectl -n nats create secret generic nats-auth \
	  --from-file=token=/tmp/nats-token \
	  --dry-run=client -o yaml \
	| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
	> /tmp/nats-auth-sealedsecret.yaml"; \
	ssh $(N150_HOST) "kubectl -n default create secret generic nats-client-auth \
	  --from-file=token=/tmp/nats-token \
	  --dry-run=client -o yaml \
	| kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml \
	> /tmp/nats-client-auth-sealedsecret.yaml && rm -f /tmp/nats-token"; \
	scp $(N150_HOST):/tmp/nats-auth-sealedsecret.yaml "$(NATS_SERVER_SECRET_FILE)"; \
	scp $(N150_HOST):/tmp/nats-client-auth-sealedsecret.yaml "$(NATS_CLIENT_SECRET_FILE)"; \
	ssh $(N150_HOST) "rm -f /tmp/nats-auth-sealedsecret.yaml /tmp/nats-client-auth-sealedsecret.yaml"
	@echo "Review and commit $(NATS_SERVER_SECRET_FILE) and $(NATS_CLIENT_SECRET_FILE)."

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
