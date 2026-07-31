.PHONY: install uninstall install-skills doctor report reclaim compact lint

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

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/* install.sh uninstall.sh; \
	else \
		echo "shellcheck not installed — skipping (sudo apt install shellcheck)"; \
	fi
