# Generic Sandcastle Dockerfile — starting point for adopting projects.
#
# This is a baseline. Customise per-project: add language runtimes, build tools,
# project-specific CLIs. Anything unique to your project belongs in YOUR project's
# .sandcastle/Dockerfile, not here.

FROM node:22-bookworm-slim

ARG AGENT_UID=1000
ARG AGENT_GID=1000

# System deps every project tends to need
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    less \
    openssh-client \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (uncomment if your project tracks issues on GitHub)
# RUN type -p curl >/dev/null && \
#     curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
#     echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list && \
#     apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# GitLab CLI (uncomment if your project tracks issues on GitLab)
# Pin a specific version for reproducibility — bump as needed.
# ARG GLAB_VERSION=1.94.0
# RUN ARCH=$(dpkg --print-architecture) && \
#     curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/glab/${GLAB_VERSION}/glab_${GLAB_VERSION}_linux_${ARCH}.deb" -o /tmp/glab.deb && \
#     apt-get install -y /tmp/glab.deb && rm /tmp/glab.deb

# Claude Code CLI (required for the agent to run)
RUN npm install -g @anthropic-ai/claude-code

# Non-root agent user — Claude Code refuses to run as root
RUN groupadd -g ${AGENT_GID} agent && \
    useradd -m -u ${AGENT_UID} -g ${AGENT_GID} -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER agent
WORKDIR /workspace

# Project-specific deps go here. Examples:
# RUN npm install -g pnpm
# RUN curl -L https://foundry.paradigm.xyz | bash && /home/agent/.foundry/bin/foundryup
# RUN pip install --user some-package

# Bake matt pocock's skills into the image so AFK agents inside the
# sandbox can invoke /tdd, /grill-me, /to-prd, /to-issues, /diagnose,
# /triage etc. via the Skill tool natively. Without this, the agent
# inside the container has Claude Code installed but no skills — the
# in-container experience is degraded vs. the host.
#
# Default ON in this template because heavy-TDD is the workflow default
# (see afk-workflow/docs/tdd-defaults.md). Comment out only if you have
# a specific reason to ship a skill-less image.
RUN npx -y skills@latest add mattpocock/skills -y -g

# Keep the container alive so Sandcastle can `docker exec` into it.
# Without this, the base image's default CMD (`node` for the node base)
# exits immediately when run detached and Sandcastle gets "container
# not running" errors (captured from a real tracer-bullet run).
CMD ["sleep", "infinity"]
