import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from services import Disk,DiskHTTPError,RemoteMissing
from core import UserError

class DiskPublication(unittest.TestCase):
 def test_waits_for_public_url_without_republishing(self):
  disk=Disk('fake');calls=[];answers=iter([{}, {}, {'public_url':'https://disk.yandex.ru/d/test'}])
  def request(method,endpoint,**params):calls.append((method,endpoint,params));return next(answers)
  disk.request=request
  with patch('services.time.sleep') as sleep:self.assertEqual(disk.public_link('disk:/test'),'https://disk.yandex.ru/d/test')
  self.assertEqual(sleep.call_count,2);self.assertTrue(all(c[0]=='GET' for c in calls))
 def test_temporary_errors_and_unpublished_metadata_recover(self):
  disk=Disk('fake')
  with patch.object(disk,'request',side_effect=[DiskHTTPError(503,'temporary'),DiskHTTPError(429,'rate'),RemoteMissing('pending'),UserError('Нет ответа Яндекс Диска. Проверьте интернет.'),{'public_url':'https://disk.yandex.ru/d/ready'}]),patch('services.time.sleep'):
   self.assertEqual(disk.public_link('disk:/test'),'https://disk.yandex.ru/d/ready')
 def test_permission_error_not_retried(self):
  disk=Disk('fake')
  with patch.object(disk,'request',side_effect=DiskHTTPError(403,'denied')) as request,patch('services.time.sleep'):
   with self.assertRaises(DiskHTTPError):disk.public_link('disk:/test')
  self.assertEqual(request.call_count,1)
 def test_bounded_wait_keeps_actionable_error(self):
  disk=Disk('fake')
  with patch.object(disk,'request',return_value={}) as request,patch('services.time.sleep') as sleep:
   with self.assertRaisesRegex(UserError,'Архив загружен и проверен'):disk.public_link('disk:/test')
  self.assertEqual(request.call_count,10);self.assertEqual(sum(c.args[0] for c in sleep.call_args_list),59)
 def test_rejects_invalid_link(self):
  disk=Disk('fake')
  for url in ['http://disk.yandex.ru/d/unsafe','javascript:alert(1)','https:///missing','https://user:password@example.com/file']:
   with patch.object(disk,'request',return_value={'public_url':url}):
    with self.assertRaisesRegex(UserError,'некорректную'):disk.public_link('disk:/test')
 def test_real_upload_publishes_once_and_checks_integrity_before_link(self):
  import hashlib
  disk=Disk('fake');calls=[];data=b'test archive';md5=hashlib.md5(data).hexdigest();reads=[{}, {}, {'public_url':'https://disk.yandex.ru/d/delayed'}]
  class Response:
   status=201
   def __enter__(self):return self
   def __exit__(self,*args):pass
  def request(method,endpoint,**params):
   calls.append((method,endpoint,params))
   if endpoint=='':return {'total_space':1000,'used_space':0}
   if endpoint=='/resources/upload':return {'href':'https://upload.disk.yandex.net/test'}
   if params.get('fields')=='size,md5':return {'size':len(data),'md5':md5}
   if params.get('fields')=='public_url':return reads.pop(0)
   return {}
  disk.request=request
  with tempfile.TemporaryDirectory() as tmp:
   archive=Path(tmp)/'test.zip';archive.write_bytes(data)
   with patch('services.urllib.request.urlopen',return_value=Response()) as upload,patch('services.time.sleep'):
    self.assertEqual(disk.upload(archive,'disk:/Cloudshop-Print/'+'a'*32+'_'+'b'*32+'/Полароид.zip'),'https://disk.yandex.ru/d/delayed')
   self.assertEqual(upload.call_count,1)
  self.assertEqual(sum(c[1]=='/resources/publish' for c in calls),1)
