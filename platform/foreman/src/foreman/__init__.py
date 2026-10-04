"""Foreman: control plane of the autonomous development platform."""

__version__ = "0.1.0"


def main() -> None:
    import logging

    import uvicorn

    from foreman.app import create_app
    from foreman.config import Settings

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = Settings()  # refuses local mode on a non-loopback bind
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port, proxy_headers=False,
                server_header=False)
