"""Throttled real progress cards; edits are best effort and never fail a file transfer."""
import asyncio
import time

class ProgressCards:
    def __init__(self,worker):self.w=worker;self.cards={};self.last={};self.locks={}
    async def update(self,key,chat,title,stage,done=None,total=None,buttons=None,force=False):
        lock=self.locks.setdefault(key,asyncio.Lock())
        async with lock:
            return await self._update(key,chat,title,stage,done,total,buttons,force)
    async def _update(self,key,chat,title,stage,done=None,total=None,buttons=None,force=False):
        now=time.monotonic()
        if not force and now-self.last.get(key,0)<3:return
        self.last[key]=now
        text=title+'\n'+stage
        if total and done is not None:
            fraction=max(0,min(1,done/total));bars=int(fraction*10)
            text+='\n'+'▰'*bars+'▱'*(10-bars)+f' {fraction:.0%}'
        try:
            if key in self.cards:await self.cards[key].edit(text,buttons=buttons,parse_mode=None)
            else:self.cards[key]=await self.w.client.send_message(chat,text,buttons=buttons,parse_mode=None)
        except Exception:pass
    def thread_callback(self,key,chat,title,stage):
        last=[0.]
        def update(done,total):
            now=time.monotonic()
            if now-last[0]<3:return
            last[0]=now
            loop=self.w.loop
            if loop and not loop.is_closed():
                asyncio.run_coroutine_threadsafe(self.update(key,chat,title,stage,done,total),loop)
        return update
