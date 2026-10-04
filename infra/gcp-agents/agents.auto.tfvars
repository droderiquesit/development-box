# One Cloud Run service per key. Add a line to spin up another agent; each
# gets its own URL, Google sign-in and saved state. Merge → approve deploy.
agents = {
  main = {}
  # frontend = { model = "zai-org/glm-5.2-maas" }
  # architect = { model = "moonshotai/kimi-k2-thinking-maas", memory = "8Gi" }
}
