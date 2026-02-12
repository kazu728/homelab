.PHONY: build build-n150 seal-argocd-repo llm-smoke llm-chat llm-chat-reset llm-chat-show
N150_HOST ?= n150
N150_STAGE_DIR ?= /tmp/nixos-sync
ARGOCD_REPO_KEY ?= ~/.ssh/argocd_homelab
LLM_CHAT_MODEL ?= qwen2.5:14b
LLM_CHAT_STATE ?= /tmp/homelab-llm-chat.json

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

llm-smoke:
	ssh -t $(N150_HOST) 'set -euo pipefail; \
		echo "[llm-smoke] checking tags"; \
		curl --fail --silent --show-error http://127.0.0.1:11434/api/tags >/dev/null; \
		echo "[llm-smoke] running short generation"; \
		curl --fail --silent --show-error http://127.0.0.1:11434/api/generate \
		  -H "Content-Type: application/json" \
		  --data "{\"model\":\"qwen2.5:14b\",\"prompt\":\"Reply with OK.\",\"stream\":false,\"options\":{\"num_predict\":16}}" \
		| grep -q "response"; \
		echo "[llm-smoke] ok"'

llm-chat:
	@LLM_CHAT_MODEL="$(LLM_CHAT_MODEL)" \
	LLM_CHAT_STATE="$(LLM_CHAT_STATE)" \
	./scripts/llm-chat.sh chat "$(or $(PROMPT),hello)"

llm-chat-reset:
	@LLM_CHAT_MODEL="$(LLM_CHAT_MODEL)" \
	LLM_CHAT_STATE="$(LLM_CHAT_STATE)" \
	./scripts/llm-chat.sh reset

llm-chat-show:
	@LLM_CHAT_STATE="$(LLM_CHAT_STATE)" \
	./scripts/llm-chat.sh show
