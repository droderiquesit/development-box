#!/usr/bin/env bash
# Thin alias so the health check has a stable path independent of the CLI layout.
exec /opt/devbox/bin/devbox doctor "$@"
