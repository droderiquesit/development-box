# Additional CA certificates

Drop any extra trusted root CAs here as `*.crt` (PEM) files **before** building.

This exists for one reason: enterprises run TLS-inspecting egress proxies. Without
the proxy's root CA in the image trust store, every `apt`, `curl`, `go install`,
`npm install` and `uv tool install` inside the build fails with an opaque
certificate error.

Certificates placed here are installed into `/usr/local/share/ca-certificates`
and registered with `update-ca-certificates` in the **base** image, so both
images and every tool that reads the system trust store pick them up.

Nothing sensitive belongs here — a root CA certificate is public by definition.
Private keys are rejected by the pre-commit `detect-private-key` hook.

## Why this needs more than `update-ca-certificates`

Installing a root CA into the OS trust store is necessary but not sufficient.
Several toolchains in this image ship their own CA bundle and ignore the OS
store entirely:

| Tool | Bundle it uses by default |
|---|---|
| `uv` | webpki (compiled in) |
| Node / npm | a compiled-in list |
| Python `requests` | certifi |
| `git` | its own build-time setting |

So `config/shell/00-env.sh` points every one of them at the system bundle:

```sh
SSL_CERT_FILE, SSL_CERT_DIR, CURL_CA_BUNDLE, REQUESTS_CA_BUNDLE,
NODE_EXTRA_CA_CERTS, GIT_SSL_CAINFO, UV_NATIVE_TLS=true
```

Without that, a correctly-installed corporate CA still produces
`invalid peer certificate: UnknownIssuer` from `uv tool install` — which is a
genuinely confusing failure, because `curl` to the same host works fine.
