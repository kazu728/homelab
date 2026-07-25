.PHONY: build access-list
N150_HOST ?= n150
RSYNC_FLAGS := -av --no-perms --no-owner --no-group --omit-dir-times

build:
	stage=$$(ssh $(N150_HOST) 'mktemp -d') && \
	trap 'ssh $(N150_HOST) "rm -rf $$stage"' EXIT && \
	rsync $(RSYNC_FLAGS) -z --relative --exclude .git -e "ssh" ./flake.nix ./flake.lock ./.sops.yaml ./hosts ./k8s/bootstrap $(N150_HOST):$$stage/ && \
	ssh -t $(N150_HOST) "sudo mkdir -p /etc/nixos/hosts /etc/nixos/k8s/bootstrap && sudo rm -f /etc/nixos/configuration.nix && sudo rsync $(RSYNC_FLAGS) $$stage/flake.nix $$stage/flake.lock $$stage/.sops.yaml /etc/nixos/ && sudo rsync $(RSYNC_FLAGS) --delete $$stage/hosts/ /etc/nixos/hosts/ && sudo rsync $(RSYNC_FLAGS) --delete $$stage/k8s/bootstrap/ /etc/nixos/k8s/bootstrap/ && cd /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#nixos --option extra-experimental-features 'nix-command flakes'"

access-list:
	@host="$${HOMELAB_HOST:-$$(ssh $(N150_HOST) 'tailscale status --json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"; \
	[ -n "$$host" ] || { echo "HOMELAB_HOST is empty" >&2; exit 1; }; \
	case "$$host" in (*[!A-Za-z0-9._:-]*) echo "Invalid HOMELAB_HOST: $$host" >&2; exit 1;; esac; \
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
