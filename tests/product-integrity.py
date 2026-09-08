#!/usr/bin/env python3
"""Cross-component regressions using real drivers and a strictly offline CLI."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'plugins/cc-codex-triage/scripts'
FAKE = '''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys,time
if '--version' in sys.argv: print('codex-cli test'); sys.exit(0)
sys.stdin.read()
pathlib.Path(os.environ['CALLS']).write_text(json.dumps(sys.argv))
if os.environ.get('CHILD'):
 subprocess.Popen([sys.executable,'-c',"import time,pathlib; time.sleep(3); pathlib.Path("+repr(os.environ['CHILD'])+").write_text('survived')"])
 pathlib.Path(os.environ['READY']).write_text(str(os.getpid()))
 time.sleep(30)
pathlib.Path(sys.argv[sys.argv.index('-o')+1]).write_text(os.environ.get('VERDICT','APPROVE')+'\\n')
print(json.dumps({'type':'thread.started','thread_id':'11111111-1111-4111-8111-111111111111'}))
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':12,'output_tokens':3}}))
'''


class ProductIntegrity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        binary = self.root / 'bin'
        binary.mkdir()
        (binary / 'codex').write_text(FAKE)
        (binary / 'codex').chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary)+':'+os.environ['PATH'],
                        CLAUDE_PROJECT_DIR=str(self.repo), CALLS=str(self.root/'calls'))
        for args in [('init','-q','-b','main'), ('config','user.name','test'),
                     ('config','user.email','test@example.invalid')]:
            self.git(*args)
        (self.repo/'spec.md').write_text('VALUE must be 1\n')
        (self.repo/'subject.py').write_text('VALUE = 1\n')
        self.git('add','spec.md','subject.py'); self.git('commit','-qm','base')
        self.base = self.git('rev-parse','HEAD').stdout.strip()
        (self.repo/'subject.py').write_text('VALUE = 2\n')
        self.git('commit','-qam','candidate')
        self.head = self.git('rev-parse','HEAD').stdout.strip()
        self.prompt = f'REQUIRED_REVIEW\nBASE_SHA: {self.base}\nCANDIDATE_SHA: {self.head}\nSPEC_PATH: spec.md\nReview the full candidate.\n'
        self.sd = self.repo/'.git/cc-codex-triage/threads'

    def run_cmd(self, args, prompt=None):
        return subprocess.run([str(x) for x in args], cwd=self.repo, env=self.env,
                              input=prompt, text=True, capture_output=True, timeout=20)

    def git(self, *args):
        p=self.run_cmd(['git',*args]); self.assertEqual(p.returncode,0,p.stderr); return p

    def gate(self, *args):
        return self.run_cmd(['bash',SCRIPTS/'review-state.sh',*args])

    def begin(self):
        p=self.gate('begin','review','--base',self.base,'--spec','spec.md','--cap','3')
        self.assertEqual(p.returncode,0,p.stderr)
        return re.search(r'claim=([a-f0-9]+)',p.stdout)[1]

    def dispatch(self, *args, prompt=None):
        return self.run_cmd(['bash',SCRIPTS/'codex-thread.sh','review',*args], prompt or self.prompt)

    def approve(self):
        claim=self.begin(); p=self.dispatch('--strict')
        self.assertEqual(p.returncode,0,p.stderr)
        p=self.gate('record','review',claim); self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.gate('check','review').returncode,0)

    def test_changed_input_never_reaches_callee_or_earns_approval(self):
        claim=self.begin()
        (self.repo/'subject.py').write_text('VALUE = 1\n')
        self.assertNotEqual(self.dispatch('--strict').returncode,0)
        self.assertFalse((self.root/'calls').exists())
        (self.repo/'subject.py').write_text('VALUE = 2\n')
        self.assertNotEqual(self.gate('record','review',claim).returncode,0)
        self.assertNotEqual(self.gate('check','review').returncode,0)

    def test_later_negative_reply_revokes_approval_preserving_history(self):
        self.approve(); session=(self.sd/'review.id').read_text()
        self.env['VERDICT']='REQUEST_CHANGES'
        p=self.dispatch('--require-existing',prompt='Re-evaluate this candidate.\n')
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('REQUEST_CHANGES',p.stdout)
        self.assertNotEqual(self.gate('check','review').returncode,0)
        self.assertEqual((self.sd/'review.id').read_text(),session)
        self.assertIn('APPROVE',(self.sd/'review.log').read_text())
        self.assertIn('REQUEST_CHANGES',(self.sd/'review.log').read_text())

    def test_controls_apply_to_resumed_conversation(self):
        self.assertEqual(self.dispatch().returncode,0)
        p=self.dispatch('--read-only','--model','test-model','--effort','high')
        self.assertEqual(p.returncode,0,p.stderr)
        args=json.loads((self.root/'calls').read_text())
        for flag,value in [('-s','read-only'),('-m','test-model'),('-c','model_reasoning_effort=high')]:
            self.assertEqual(args[args.index(flag)+1],value)
            self.assertLess(args.index(flag),args.index('resume'))
        usage=json.loads((self.sd/'review.last-usage.json').read_text())
        self.assertEqual(usage['model_requested'],'test-model')
        self.assertEqual(usage['effort_requested'],'high')
        self.assertEqual(usage['usage']['input_tokens'],12)
        self.assertIsNone(usage['cost_usd'])

    def test_cancellation_stops_grandchild(self):
        marker=self.root/'child';ready=self.root/'ready'
        self.env.update(CHILD=str(marker),READY=str(ready))
        with open(self.root/'out','w') as out:
            p=subprocess.Popen(['bash',str(SCRIPTS/'codex-thread.sh'),'review'],cwd=self.repo,
                               env=self.env,stdin=subprocess.PIPE,stdout=out,stderr=out,text=True)
            p.stdin.write('offline cancellation test\n');p.stdin.close()
            deadline=time.monotonic()+8
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.05)
            self.assertTrue(ready.exists())
            p.terminate();self.assertEqual(p.wait(timeout=8),143)
        time.sleep(3.2)
        self.assertFalse(marker.exists(),'callee grandchild survived cancellation')
        self.assertFalse((self.sd/'review.active').exists())


    def research_recipe(self):
        command=(SCRIPTS.parent/'commands/research.md').read_text()
        return command.split('```bash\n',1)[1].split('```',1)[0]

    def test_research_recipe_preserves_search_read_only_and_conversation(self):
        self.git('checkout','-qb','feature/research')
        self.env.update(CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),PROMPT='Compare recovery approaches.',
                        VERDICT='Recommendation with sources; no review verdict.')
        for resumed in [False,True]:
            p=self.run_cmd(['bash','-c',self.research_recipe()])
            self.assertEqual(p.returncode,0,p.stderr)
            args=json.loads((self.root/'calls').read_text())
            self.assertIn('web_search="live"',args)
            self.assertEqual(args[args.index('-s')+1],'read-only')
            self.assertEqual('resume' in args,resumed)
            if resumed:
                self.assertLess(args.index('web_search="live"'),args.index('resume'))
            self.assertIn('Recommendation with sources',p.stdout)
        thread='research-feature-research'
        self.assertEqual((self.sd/(thread+'.rounds')).read_text().strip(),'2')
        self.assertTrue((self.sd/(thread+'.id')).is_file())
        self.assertFalse((self.sd/(thread+'.candidate')).exists())
        self.assertFalse((self.sd/(thread+'.approved')).exists())
        self.assertEqual(self.git('status','--porcelain').stdout,'')

    def test_research_recipe_leaves_required_thread_approval_untouched(self):
        self.approve()
        prior=(self.root/'calls').read_bytes()
        self.env.update(CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),THREAD='review',PROMPT='Research a question.')
        p=self.run_cmd(['bash','-c',self.research_recipe()])
        self.assertNotEqual(p.returncode,0)
        self.assertEqual((self.root/'calls').read_bytes(),prior)
        self.assertEqual(self.gate('check','review').returncode,0)

    def test_reset_archives_session_and_log_before_clearing(self):
        self.approve()
        session=(self.sd/'review.id').read_bytes()
        log=(self.sd/'review.log').read_bytes()
        p=self.run_cmd(['bash',SCRIPTS/'codex-thread.sh','review','--reset-only'])
        self.assertEqual(p.returncode,0,p.stderr)
        archives=list(self.sd.glob('review.archive.*'))
        self.assertEqual(len(archives),1)
        self.assertTrue(archives[0].is_file())
        with tarfile.open(archives[0]) as archive:
            self.assertEqual(archive.extractfile('review.id').read(),session)
            self.assertEqual(archive.extractfile('review.log').read(),log)
        self.assertFalse((self.sd/'review.id').exists())
        self.assertNotEqual(self.gate('check','review').returncode,0)

if __name__ == '__main__':
    unittest.main()
