"""Local Windows preflight; prints no passwords, tokens, or API hashes."""
import platform
import sys
import tempfile
from pathlib import Path
from services import Settings,protect
print('Windows:',platform.system(),platform.release())
print('Python:',sys.version.split()[0])
try:
    import tkinter
    import telethon
    print('Tk:',tkinter.TkVersion)
    print('Telethon:',telethon.__version__)
    assert protect(protect(b'local encryption self-test'),decrypt=True)==b'local encryption self-test'
    with tempfile.TemporaryDirectory() as folder:
        store=Settings(Path(folder)/'protected-test')
        store.save({'test':'not a real credential'})
        assert store.load()=={'test':'not a real credential'}
    print('DPAPI and local file protection: OK')
    print('Credentials and network were not inspected. No mail was sent.')
except Exception as e:
    print('Preflight failed:',type(e).__name__)
    print('Ничего не отправлялось. Сообщите эту ошибку в чат.')
    sys.exit(1)
