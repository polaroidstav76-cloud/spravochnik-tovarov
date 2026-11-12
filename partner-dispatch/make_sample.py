"""Generate a small, original, uncompressed RGB TIFF test fixture (300 ppi)."""
import struct
from pathlib import Path

def make(path):
    w=h=118
    description=b'TEST ONLY - DO NOT PRINT. Cloudshop connection test.\x00'
    start=8+2+14*12+4
    bits=start;desc=bits+6
    rat=(desc+len(description)+1)//2*2
    pixel=rat+16
    entries=[(256,4,1,w),(257,4,1,h),(258,3,3,bits),(259,3,1,1),(262,3,1,2),
             (270,2,len(description),desc),(273,4,1,pixel),(277,3,1,3),(278,4,1,h),
             (279,4,1,w*h*3),(282,5,1,rat),(283,5,1,rat+8),(284,3,1,1),(296,3,1,2)]
    data=bytearray(b'II'+struct.pack('<HI',42,8)+struct.pack('<H',len(entries)))
    for tag,kind,count,value in entries:
        data+=struct.pack('<HHI',tag,kind,count)
        data+=struct.pack('<H',value)+b'\0\0' if kind==3 and count==1 else struct.pack('<I',value)
    data+=struct.pack('<I',0)+struct.pack('<HHH',8,8,8)+description
    data+=b'\0'*(rat-len(data))+struct.pack('<IIII',300,1,300,1)
    assert len(data)==pixel
    for y in range(h):
        for x in range(w):
            red=abs(x-y)<4 or abs((w-1-x)-y)<4 or min(x,y,w-1-x,h-1-y)<3
            data+=bytes((220,20,20) if red else (255,255,255))
    Path(path).write_bytes(data)

if __name__=='__main__':make(Path(__file__).parent/'ТЕСТ_НЕ_ПЕЧАТАТЬ_1х1см.tif')
