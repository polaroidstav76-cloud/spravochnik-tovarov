"""Device-scoped cloud API; never uses a Supabase service key on a PC."""
import json
import platform
import re
import urllib.error
import urllib.request
from core import UserError

ENDPOINT='https://tmxluzvymwldtxbaiekn.supabase.co/functions/v1/print-bridge'

class BridgeClient:
    def __init__(self,token=''):self.token=token
    def request(self,action,payload=None):
        headers={'Content-Type':'application/json'}
        if self.token:headers['X-Device-Token']=self.token
        req=urllib.request.Request(ENDPOINT,data=json.dumps({'action':action,'payload':payload or {}},ensure_ascii=False).encode(),headers=headers,method='POST')
        try:
            with urllib.request.urlopen(req,timeout=40) as response:result=json.load(response)
            return result['result']
        except urllib.error.HTTPError as e:
            if e.code in (401,403):raise UserError('Доступ компьютера не подключён или отключён. Получите новый код в Клаудшопе.') from None
            raise UserError('Клаудшоп не принял запрос. Проверьте подключение и параметры задания.') from None
        except (OSError,ValueError,KeyError):raise ConnectionError('Нет связи с Клаудшопом. Повторим позже.') from None
    @classmethod
    def pair(cls,code,role):
        code=code.strip()
        if not re.fullmatch('[a-f0-9]{32}',code):raise UserError('Вставьте одноразовый код подключения из Клаудшопа.')
        result=cls().request('pair',{'code':code,'expected_role':role,'label':platform.node()[:80] or 'Windows'})
        if result.get('role')!=role:raise UserError('Это код другого режима. Создайте код для нужного компьютера.')
        return result
