.PHONY: build access-list
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
RSYNC_FLAGS := -av --no-perms --no-owner --no-group --omit-dir-times

build:
	ssh $(N150_HOST) "rm -rf $(N150_STAGE_DIR) && mkdir -p $(N150_STAGE_DIR)"
	rsync $(RSYNC_FLAGS) -z --relative --exclude .git -e "ssh" ./flake.nix ./flake.lock ./.sops.yaml ./hosts ./k8s/bootstrap $(N150_HOST):$(N150_STAGE_DIR)/
	ssh -t $(N150_HOST) "sudo mkdir -p /etc/nixos/hosts /etc/nixos/k8s/bootstrap && sudo rm -f /etc/nixos/configuration.nix && sudo rsync $(RSYNC_FLAGS) $(N150_STAGE_DIR)/flake.nix $(N150_STAGE_DIR)/flake.lock $(N150_STAGE_DIR)/.sops.yaml /etc/nixos/ && sudo rsync $(RSYNC_FLAGS) --delete $(N150_STAGE_DIR)/hosts/ /etc/nixos/hosts/ && sudo rsync $(RSYNC_FLAGS) --delete $(N150_STAGE_DIR)/k8s/bootstrap/ /etc/nixos/k8s/bootstrap/ && cd /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#nixos --option extra-experimental-features 'nix-command flakes'"

access-list:
	@host="$${HOMELAB_HOST:-$$(ssh $(N150_HOST) 'tailscale status --json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"; \
	[ -n "$$host" ] || { echo "HOMELAB_ACCESS_HOST is empty" >&2; exit 1; }; \
	case "$$host" in (*[!A-Za-z0-9._:-]*) echo "Invalid HOMELAB_ACCESS_HOST: $$host" >&2; exit 1;; esac; \
	remote_cmd=$$(printf '%s\n' \
		"sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml HOMELAB_ACCESS_HOST=$$host sh <<'REMOTE_SCRIPT'" \
		"set -eu" \
		"grafana_user=\$$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 --decode)" \
		"grafana_pass=\$$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 --decode)" \
		"argo_pass_base64=\$$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')" \
		"argo_pass=\$$(printf '%s' \"\$$argo_pass_base64\" | base64 --decode)" \
		"printf 'Homelab access endpoints:\\n'" \
		"printf '  Grafana: https://%s/\\n' \"\$$HOMELAB_ACCESS_HOST\"" \
		"printf '  Argo CD: https://%s:8443/\\n\\n' \"\$$HOMELAB_ACCESS_HOST\"" \
		"printf 'Credentials:\\n'" \
		"printf '  Grafana:\\n'" \
		"printf '    user: %s\\n' \"\$$grafana_user\"" \
		"printf '    pass: %s\\n' \"\$$grafana_pass\"" \
		"printf '  Argo CD:\\n'" \
		"printf '    user: admin\\n'" \
		"printf '    pass: %s\\n' \"\$$argo_pass\"" \
		"REMOTE_SCRIPT" \
	); \
	ssh -o LogLevel=ERROR -tt $(N150_HOST) "$$remote_cmd"
