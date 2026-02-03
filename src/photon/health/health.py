import socket
import time
import logging
import requests
import threading

LISTEN_PORT = 2320
CHECK_URL = "http://localhost:2322/status"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s health: %(message)s",
)
logger = logging.getLogger("health")

logger.info("Starting: check_url=%s listen_port=%d", CHECK_URL, LISTEN_PORT)

listener = None
accept_thread = None

def accept_loop(sock):
    while True:
        try:
            conn, addr = sock.accept()
            conn.close()  # complete handshake, immediately close
        except OSError:
            logging.info("Listener socket closed - giving up. Exception: %s", OSError)
            break
        except Exception:
            logging.info("Error on listen socket - ignoring. Exception: %s", OSError)
            pass

while True:
    healthy = False
    try:
        r = requests.get(CHECK_URL, timeout=1)
        healthy = r.status_code == 200
    except Exception:
        healthy = False

    if healthy and listener is None:
        logger.info("Healthy; opening listener on 0.0.0.0:%d", LISTEN_PORT)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", LISTEN_PORT))
        listener.listen(5)

        accept_thread = threading.Thread(target=accept_loop, args=(listener,), daemon=True)
        accept_thread.start()

    if not healthy and listener is not None:
        logger.info("Unhealthy; closing listener on 0.0.0.0:%d", LISTEN_PORT)
        listener.close()
        listener = None
        accept_thread = None

    time.sleep(2)
