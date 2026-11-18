import ast
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import unittest
from background import task_script

class BackgroundTests(unittest.TestCase):
    def test_command_uses_same_user_profile_and_no_secrets_or_shell_paths(self):
        path='C:/Печать/strange "+$(test);/Cloudshop.exe'
        script=task_script(path,'--background --autostart')
        payload=re.search("FromBase64String\\('([^']+)'\\)",script).group(1)
        config=json.loads(base64.b64decode(payload))
        self.assertEqual(config['exe'],path)
        self.assertIn('-LogonType Interactive',script)
        self.assertIn('-AtLogOn -User $sid',script)
        self.assertIn('-MultipleInstances IgnoreNew',script)
        self.assertIn('-RestartInterval (New-TimeSpan -Minutes 1)',script)
        self.assertNotIn(path,script)
        self.assertNotIn('SYSTEM',script)
    def test_disabling_unregisters_and_does_not_delete_credentials(self):
        script=task_script('C:/program.exe','--background --autostart',False)
        self.assertIn('Unregister-ScheduledTask',script)
        self.assertNotIn('Remove-Item',script)
    @unittest.skipUnless(os.name=='nt','Native PowerShell parser checked on Windows')
    def test_powershell_syntax_without_registering_a_task(self):
        source=task_script('C:/Печать/Cloudshop.exe','--background --autostart')
        payload=base64.b64encode(source.encode()).decode()
        checker="$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+payload+"'));$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($s,[ref]$t,[ref]$e);if($e.Count){exit 1}"
        encoded=base64.b64encode(checker.encode('utf-16le')).decode()
        result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',encoded],capture_output=True,timeout=30)
        self.assertEqual(result.returncode,0)

    def test_stop_during_initial_connection_cannot_start_bot_later(self):
        import asyncio,tempfile
        from unittest.mock import patch
        from core import Queue
        from worker import Worker
        with tempfile.TemporaryDirectory() as folder:
            queue=Queue(folder);worker=Worker(queue,{'bot_token':'123:test'},lambda x:None)
            def check(token):worker.stop()
            with patch('worker.check_dedicated_bot',side_effect=check):asyncio.run(worker.run())
            self.assertIsNone(worker.client)
            queue.db.close()
