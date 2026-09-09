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

    def test_unusable_python_fails_before_dispatch_or_state_changes(self):
        self.approve()
        self.env['TMPDIR'] = str(self.root)
        before = {p.name: p.read_bytes() for p in self.sd.iterdir()}
        (self.root/'calls').unlink()
        interpreter = self.root/'bin/python3'
        interpreter.write_text('#!/bin/sh\necho "broken interpreter" >&2\nexit 127\n')
        interpreter.chmod(0o755)
        for flags in [(), ('--new',), ('--oneshot',), ('--detach',)]:
            with self.subTest(flags=flags):
                p = self.dispatch(*flags)
                self.assertEqual(p.returncode, 2, p.stderr)
                self.assertIn('Python 3.8+', p.stderr)
                self.assertNotIn('codex exec FAILED', p.stderr)
                self.assertFalse((self.root/'calls').exists())
                self.assertEqual({p.name: p.read_bytes() for p in self.sd.iterdir()}, before)
        p = self.run_cmd(['bash', SCRIPTS/'codex-thread.sh', 'fresh'], 'hello')
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in self.sd.iterdir()}, before)
        # The long-call wrapper must not retry the same missing dependency.
        self.env['PY_PROBES'] = str(self.root/'python-probes')
        interpreter.write_text('#!/bin/sh\necho probe >> "$PY_PROBES"\nexit 127\n')
        p = self.run_cmd(['bash', SCRIPTS/'dispatch.sh', 'review'], self.prompt)
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertEqual((self.root/'python-probes').read_text().splitlines(), ['probe'])
        self.assertEqual({p.name: p.read_bytes() for p in self.sd.iterdir()}, before)
        # Git-local maintenance needs no reviewer runtime and remains available.
        self.assertEqual(self.dispatch('--reset-only').returncode, 0)

    def test_strict_rejection_records_incomplete_receipt_without_approval(self):
        claim = self.begin()
        (self.root/'bin/codex').write_text(FAKE.replace('sys.stdin.read()',
            "sys.stdin.read()\npathlib.Path('subject.py').write_text('VALUE = 3\\n')"))
        p = self.dispatch('--strict')
        self.assertEqual(p.returncode, 5, p.stderr)
        self.assertIn('status=started', (self.sd/'review.dispatch-receipt').read_text())
        (self.repo/'subject.py').write_text('VALUE = 2\n')
        p = self.gate('abort', 'review', 'dispatch-failure', claim)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertIn('ROUND_COMPLETED', p.stderr)
        p = self.gate('record', 'review', claim)
        self.assertEqual(p.returncode, 11, p.stderr)
        self.assertIn('dispatch_incomplete', p.stderr)
        self.assertNotEqual(self.gate('check', 'review').returncode, 0)

    def test_corrupt_claim_does_not_destroy_budget_and_saved_state_can_recover(self):
        claim = self.begin()
        candidate = self.sd/'review.candidate'
        saved = candidate.read_text()
        loop = (self.sd/'review.review-loop').read_bytes()
        candidate.write_text(saved.replace(claim, 'not-a-valid-token'))
        p = self.gate('record', 'review', claim)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertIn('INVALID_CLAIM_STATE', p.stderr)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(), loop)
        self.assertNotEqual(self.gate('check', 'review').returncode, 0)
        # Restore a known intact snapshot, rather than inventing replacement fields.
        candidate.write_text(saved)
        self.assertEqual(self.dispatch('--strict').returncode, 0)
        self.assertEqual(self.gate('record', 'review', claim).returncode, 0)
        self.assertEqual(self.gate('check', 'review').returncode, 0)
        self.assertEqual((self.sd/'review.review-loop').read_bytes(), loop)

    def test_standalone_maintenance_reports_broken_python_without_touching_state(self):
        context = self.root/'standalone'; context.mkdir()
        self.env.update(CLAUDE_PROJECT_DIR=str(context), XDG_STATE_HOME=str(self.root/'state'))
        self.assertEqual(self.dispatch().returncode, 0)
        p = self.run_cmd(['bash', SCRIPTS/'state-dir.sh', '--read-only'])
        self.assertEqual(p.returncode, 0, p.stderr)
        state = Path(p.stdout.strip())
        before = {p.name: p.read_bytes() for p in state.iterdir()}
        (self.root/'calls').unlink()
        interpreter = self.root/'bin/python3'
        interpreter.write_text('#!/bin/sh\necho "broken interpreter" >&2\nexit 127\n')
        interpreter.chmod(0o755)
        for script, args in [('codex-thread.sh', ['review', '--reset-only']),
                             ('status.sh', []), ('thread-index.sh', []),
                             ('state-dir.sh', ['--read-only'])]:
            with self.subTest(script=script):
                p = self.run_cmd(['bash', SCRIPTS/script, *args])
                self.assertEqual(p.returncode, 2, p.stderr)
                self.assertIn('Python', p.stderr)
                self.assertIn('standalone thread state', p.stderr)
                self.assertFalse((self.root/'calls').exists())
                self.assertEqual({p.name: p.read_bytes() for p in state.iterdir()}, before)
                self.assertEqual(list(context.iterdir()), [])

    def test_complete_receipt_for_another_claim_remains_mismatched(self):
        claim = self.begin()
        self.assertEqual(self.dispatch('--strict').returncode, 0)
        receipt = self.sd/'review.dispatch-receipt'
        receipt.write_text(receipt.read_text().replace(claim, '0'*len(claim)))
        p = self.gate('record', 'review', claim)
        self.assertEqual(p.returncode, 11, p.stderr)
        self.assertIn('dispatch_candidate_mismatch', p.stderr)
        self.assertNotEqual(self.gate('check', 'review').returncode, 0)

    def test_status_reports_retained_archives_without_changing_them(self):
        self.assertEqual(self.dispatch().returncode, 0)
        self.assertEqual(self.dispatch('--reset-only').returncode, 0)
        archives = list(self.sd.glob('review.archive.*'))
        self.assertEqual(len(archives), 1)
        before = {p.name: p.read_bytes() for p in self.sd.iterdir()}
        p = self.run_cmd(['bash', SCRIPTS/'status.sh'])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f'Archives: 1 file(s), {archives[0].stat().st_size} bytes', p.stdout)
        self.assertIn(str(self.sd), p.stdout)
        self.assertEqual({p.name: p.read_bytes() for p in self.sd.iterdir()}, before)


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

    def test_research_recipe_forwards_model_and_effort_only_when_supplied(self):
        # The published recipe is the producer; the fake CLI's recorded argv is the checker.
        # `${MODEL:+...}` must expand to nothing when unset and to the driver flags when set,
        # on the initial call and on resume alike.
        self.git('checkout','-qb','feature/controls')
        self.env.update(CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),PROMPT='Compare approaches.',
                        VERDICT='Recommendation.')
        p=self.run_cmd(['bash','-c',self.research_recipe()])
        self.assertEqual(p.returncode,0,p.stderr)
        args=json.loads((self.root/'calls').read_text())
        self.assertNotIn('-m',args)
        self.assertFalse(any(a.startswith('model_reasoning_effort=') for a in args))
        self.env.update(MODEL='test-model',EFFORT='high')
        p=self.run_cmd(['bash','-c',self.research_recipe()])
        self.assertEqual(p.returncode,0,p.stderr)
        args=json.loads((self.root/'calls').read_text())
        self.assertEqual(args[args.index('-m')+1],'test-model')
        self.assertEqual(args[args.index('-c',args.index('-m'))+1],'model_reasoning_effort=high')
        self.assertIn('resume',args)
        self.assertLess(args.index('-m'),args.index('resume'))

    def test_research_recipe_leaves_required_thread_approval_untouched(self):
        self.approve()
        prior=(self.root/'calls').read_bytes()
        self.env.update(CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),THREAD='review',PROMPT='Research a question.')
        p=self.run_cmd(['bash','-c',self.research_recipe()])
        self.assertNotEqual(p.returncode,0)
        self.assertEqual((self.root/'calls').read_bytes(),prior)
        self.assertEqual(self.gate('check','review').returncode,0)

    def test_standalone_research_resume_inspect_and_reset(self):
        context=self.root/'general-research'; context.mkdir()
        self.env.update(CLAUDE_PROJECT_DIR=str(context),XDG_STATE_HOME=str(self.root/'state'),
                        CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),PROMPT='Research an unrelated general question.',
                        VERDICT='Evidence and limitations.')
        for resumed in [False,True]:
            p=self.run_cmd(['bash','-c',self.research_recipe()])
            self.assertEqual(p.returncode,0,p.stderr)
            args=json.loads((self.root/'calls').read_text())
            self.assertIn('--skip-git-repo-check',args)
            self.assertEqual('resume' in args,resumed)
            self.assertEqual(Path(args[args.index('-C')+1]).resolve(),context.resolve())
        state=self.run_cmd(['bash',SCRIPTS/'state-dir.sh','--read-only'])
        self.assertEqual(state.returncode,0,state.stderr)
        self.sd=Path(state.stdout.strip());thread='research-general-research'
        for script in ['thread-index.sh','status.sh']:
            p=self.run_cmd(['bash',SCRIPTS/script])
            self.assertEqual(p.returncode,0,p.stderr); self.assertIn(thread,p.stdout)
        required=self.gate('begin',thread,'--base','HEAD','--spec','spec.md','--cap','3')
        self.assertEqual(required.returncode,7)
        self.assertIn('required review needs a Git repository',required.stderr)
        p=self.run_cmd(['bash',SCRIPTS/'codex-thread.sh',thread,'--reset-only'])
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertFalse((self.sd/(thread+'.id')).exists())
        self.assertEqual(len(list(self.sd.glob(thread+'.archive.*'))),1)
        self.assertEqual(list(context.iterdir()),[])
        self.env['CLAUDE_PROJECT_DIR']=str(self.root)
        other=self.run_cmd(['bash',SCRIPTS/'state-dir.sh','--read-only'])
        self.assertNotEqual(other.stdout,state.stdout)
        self.assertFalse(Path(other.stdout.strip()).exists())

    def test_debate_recipe_runs_outside_git(self):
        context=self.root/'general-debate';context.mkdir()
        self.env.update(CLAUDE_PROJECT_DIR=str(context),XDG_STATE_HOME=str(self.root/'state'),
                        CLAUDE_PLUGIN_ROOT=str(SCRIPTS.parent),THREAD='debate-topic',OPENING='Compare these positions.')
        recipe=(SCRIPTS.parent/'commands/debate.md').read_text().split('```bash\n',1)[1].split('```',1)[0]
        p=self.run_cmd(['bash','-c',recipe]);self.assertEqual(p.returncode,0,p.stderr)
        args=json.loads((self.root/'calls').read_text())
        self.assertIn('--skip-git-repo-check',args)
        self.assertEqual(args[args.index('-s')+1],'read-only')
        self.assertEqual(list(context.iterdir()),[])

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
