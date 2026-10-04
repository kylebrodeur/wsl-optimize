.PHONY: install uninstall install-skills doctor report reclaim compact audit lint vendor-lib

install:
	./install.sh

# Verify the install AND the host's memory/disk posture.
doctor:
	@bin/wsl-optimize-doctor

# Activate the agent-agnostic skills for Claude Code by symlinking each skill
# folder into ~/.claude/skills. Other agents can point directly at ./skills.
# Idempotent; the repo stays the source of truth.
install-skills:
	@mkdir -p "$$HOME/.claude/skills"
	@for d in skills/*/; do \
		n=$$(basename "$$d"); \
		ln -sfn "$$PWD/skills/$$n" "$$HOME/.claude/skills/$$n" && \
		echo "linked ~/.claude/skills/$$n -> $$PWD/skills/$$n"; \
	done

uninstall:
	./uninstall.sh

report:
	bin/wslreport

reclaim:
	bin/wsl-reclaim

compact:
	bin/wsl-compact

audit:
	bin/worktree-audit

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/* install.sh uninstall.sh; \
	else \
		echo "shellcheck not installed — skipping (sudo apt install shellcheck)"; \
	fi

# Refresh the vendored shared library + shared tools from agent-machine-lib.
# Vendored rather than submoduled because this repo promises zero dependencies.
vendor-lib:
	@set -e; \
	sha=$$(git ls-remote https://github.com/kylebrodeur/agent-machine-lib.git refs/heads/main | awk '{print $$1}'); \
	test -n "$$sha"; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	for f in lib/common.sh bin/worktree-audit bin/browser-guard; do \
		mkdir -p "$$tmp/$$(dirname "$$f")"; \
		curl -fsSL "https://raw.githubusercontent.com/kylebrodeur/agent-machine-lib/$$sha/$$f" \
			-o "$$tmp/$$f"; \
	done; \
	chmod +x "$$tmp/bin/worktree-audit" "$$tmp/bin/browser-guard"; \
	mv "$$tmp/lib/common.sh" lib/common.sh; \
	mv "$$tmp/bin/worktree-audit" bin/worktree-audit; \
	mv "$$tmp/bin/browser-guard" bin/browser-guard; \
	printf '%s\n' "$$sha" > lib/.vendored-from; \
	echo "refreshed lib/common.sh + bin/{worktree-audit,browser-guard} from agent-machine-lib@$$sha"
