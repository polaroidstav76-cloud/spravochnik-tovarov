"""Check original signatures without decompressing 500 MiB wide-format images."""
from pathlib import Path
from core import UserError

def validate_content(path,direction,name):
    if direction=='workshop':return
    with open(path,'rb') as f:head=f.read(16)
    actual='png' if head.startswith(b'\x89PNG\r\n\x1a\n') else 'jpeg' if head.startswith(b'\xff\xd8\xff') else 'tiff' if head[:4] in (b'II*\0',b'MM\0*',b'II+\0',b'MM\0+') else 'psd' if head.startswith(b'8BPS\0\1') else None
    expected={'.png':'png','.jpg':'jpeg','.jpeg':'jpeg','.tif':'tiff','.tiff':'tiff','.psd':'psd'}.get(Path(name).suffix.lower())
    if actual!=expected:raise UserError('Содержимое файла не соответствует расширению. Файл отклонён: пересохраните его в нужном формате, простое переименование не подходит.')
