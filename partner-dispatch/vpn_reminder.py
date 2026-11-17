"""Publish next scheduled slots to Cloudshop; no reminders on immediate/manual sends."""
import asyncio
from datetime import datetime,timedelta
from core import MOSCOW
from bridge_client import BridgeClient

class VpnReminder:
    def __init__(self,worker):self.w=worker;self.last_slots=[]
    def slots(self,now=None):
        now=now or datetime.now(MOSCOW);slots=[]
        for direction,prefix in (('wideformat',''),('dtf','dtf_')):
            if self.w.q.setting(prefix+'automatic','0')!='1' or not self.w.recipient(direction):continue
            # Keep the current warning until 15 minutes after dispatch, even once that batch is claimed.
            has_files=bool(self.w.q.waiting(direction))
            hour,minute=map(int,self.w.q.setting(prefix+'dispatch_time','12:00' if prefix else '18:00').split(':'))
            days={int(x) for x in self.w.q.setting(prefix+'dispatch_days','0,3' if prefix else '0,1,2,3,4,5,6').split(',') if x}
            for offset in range(8):
                due=(now+timedelta(days=offset)).replace(hour=hour,minute=minute,second=0,microsecond=0)
                old=any(x['direction']==direction and x['due_at']==due.isoformat() for x in self.last_slots)
                if due.weekday() in days and due>now-timedelta(minutes=15) and (has_files or old and due<=now):slots.append({'direction':direction,'due_at':due.isoformat()})
        return slots
    async def run(self):
        while self.w.running:
            try:
                if self.w.c.get('bridge_token'):
                    slots=self.slots();await asyncio.to_thread(BridgeClient(self.w.c['bridge_token']).request,'vpn_schedule',{'slots':slots});self.last_slots=slots
            except asyncio.CancelledError:raise
            except Exception:self.w.log('Напоминание о VPN в Клаудшопе ожидает подключения. Очередь печати сохранена.')
            await asyncio.sleep(60)
