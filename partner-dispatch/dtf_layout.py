"""Millimetre-aware rectangle nesting for DTF, with 90 degree rotation."""
from dataclasses import dataclass
from math import ceil,floor
from core import UserError

DPI=300

def pixels(cm):return round(float(cm)/2.54*DPI)

@dataclass(frozen=True)
class Print:
    key: str
    width: int
    height: int

@dataclass(frozen=True)
class Placement:
    key: str
    x: int
    y: int
    width: int
    height: int
    rotated: bool

@dataclass(frozen=True)
class Layout:
    width: int
    height: int
    gap: int
    margin: int
    prints: tuple

def contains(a,b):
    return a[0]<=b[0] and a[1]<=b[1] and a[0]+a[2]>=b[0]+b[2] and a[1]+a[3]>=b[1]+b[3]

def pack(items,width,height,gap,strategy='short-side'):
    """MaxRects best-short-side-fit; gaps are never added to artwork dimensions."""
    free=[(0,0,width+gap,height+gap)];placed=[]
    for item in items:
        best=None
        for rect in free:
            for rotate in (False,True):
                w,h=(item.height,item.width) if rotate else (item.width,item.height)
                rw,rh=w+gap,h+gap
                if rw<=rect[2] and rh<=rect[3]:
                    score=((rect[1],rect[0],min(rect[2]-rw,rect[3]-rh),rotate) if strategy=='bottom-left' else (min(rect[2]-rw,rect[3]-rh),max(rect[2]-rw,rect[3]-rh),rect[1],rect[0],rotate))
                    if best is None or score<best[0]:best=(score,rect[0],rect[1],w,h,rotate)
        if best is None:return None
        _,x,y,w,h,rotate=best;right=x+w+gap;bottom=y+h+gap
        updated=[]
        for fx,fy,fw,fh in free:
            if x>=fx+fw or right<=fx or y>=fy+fh or bottom<=fy:
                updated.append((fx,fy,fw,fh));continue
            if x>fx:updated.append((fx,fy,x-fx,fh))
            if right<fx+fw:updated.append((right,fy,fx+fw-right,fh))
            if y>fy:updated.append((fx,fy,fw,y-fy))
            if bottom<fy+fh:updated.append((fx,bottom,fw,fy+fh-bottom))
        unique=list(dict.fromkeys(updated))
        free=[r for i,r in enumerate(unique) if not any(i!=j and contains(other,r) for j,other in enumerate(unique))]
        placed.append(Placement(item.key,x,y,w,h,rotate))
    return placed

def arrange(items,width_cm,base_height_cm=50):
    if not items:raise UserError('Нет принтов для ДТФ.')
    if len(items)>5000:raise UserError('Слишком много копий для одного заказа: разделите его на несколько отправок (до 5000 копий).')
    width=pixels(width_cm);base=pixels(base_height_cm);margin=round(DPI*0.5/2.54)
    usable=width-2*margin
    if usable<=0:raise UserError('Ширина холста меньше полей.')
    if any(min(p.width,p.height)>usable or p.width<=0 or p.height<=0 for p in items):
        raise UserError('Один из принтов не помещается по ширине даже при повороте. Уменьшите его размер.')
    orders=[sorted(items,key=lambda p:(-max(p.width,p.height),-p.width*p.height,p.key)),
            sorted(items,key=lambda p:(-p.width*p.height,-max(p.width,p.height),p.key)),
            sorted(items,key=lambda p:(-p.height,-p.width,p.key))]
    def attempt(height,gap):
        candidates=[v for strategy in ('short-side','bottom-left') for order in orders if (v:=pack(order,usable,height-2*margin,gap,strategy)) is not None]
        return min(candidates,key=lambda v:max(p.y+p.height for p in v)) if candidates else None
    for mm in range(20,4,-1):
        gap=min(floor(DPI*2/2.54),ceil(DPI*(mm/10)/2.54))
        result=attempt(base,gap)
        if result is not None:
            return Layout(width,base,gap,margin,tuple(Placement(p.key,p.x+margin,p.y+margin,p.width,p.height,p.rotated) for p in result))
    gap=ceil(DPI*.5/2.54)
    low=base;high=base
    result=None
    while result is None:
        high*=2
        if high>=2**31:raise UserError('Холст превышает предельный размер PNG. Разделите заказ.')
        result=attempt(high,gap)
    while high-low>pixels(.1):
        middle=(low+high)//2;candidate=attempt(middle,gap)
        if candidate is None:low=middle
        else:high=middle;result=candidate
    height=max(base,max(p.y+p.height for p in result)+2*margin)
    return Layout(width,height,gap,margin,tuple(Placement(p.key,p.x+margin,p.y+margin,p.width,p.height,p.rotated) for p in result))
