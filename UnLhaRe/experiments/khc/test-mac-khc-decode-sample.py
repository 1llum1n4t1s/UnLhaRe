"""先行失敗条件: PID再利用、空/短profile、対象不一致、sampler失敗、容量超過。"""
import importlib.util
from pathlib import Path
import types
import unittest

spec = importlib.util.spec_from_file_location('decode_sample',Path(__file__).with_name('mac-khc-decode-sample.py'))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class Contracts(unittest.TestCase):
    def profile(self, pid=123, count=20, frame=True):
        return ('Process: unlhare-cli [%d]\nPath: %s\nCall graph:\n    %d Thread_55\n'
                '%s\nBinary Images:\n' % (pid,M.CLI.as_posix(),count,
                    '    + 20 unlhare::extract (in unlhare-cli) + 12\n    + ! 8 fsync (in libsystem_kernel.dylib)' if frame else '')).encode()

    def test_profile_validates_pid_path_and_application_frame(self):
        value=M.validate_profile(self.profile(),123)
        self.assertEqual(value['state'],'observed')
        self.assertEqual(value['root_samples'],20)
        self.assertTrue(value['app_frames'])
        self.assertIn('fsync',str(value['evidence_lines']))

    def test_code_zero_does_not_make_empty_short_or_wrong_profile_successful(self):
        for text in (b'',self.profile(pid=124),self.profile(count=4),self.profile(frame=False),
                     self.profile().replace(b'unlhare-cli [',b'other ['),
                     self.profile().replace(M.CLI.as_posix().encode(),b'/tmp/unlhare-cli'),
                     self.profile().replace(b'Call graph:',b'No graph:'),b'\xff'):
            with self.subTest(text=text[:30]):
                self.assertEqual(M.validate_profile(text,123)['state'],'inconclusive')

    def test_profile_bounds_and_duplicate_headers(self):
        with self.assertRaises(M.Refusal): M.validate_profile(b'x'*(M.PROFILE_LIMIT+1),123)
        self.assertEqual(M.validate_profile(self.profile()+self.profile(),123)['state'],'inconclusive')
        with self.assertRaises(M.Refusal): M.validate_profile(self.profile(),True)

    def test_only_call_graph_application_frames_count(self):
        text=self.profile(frame=False)+b'20 unlhare (in unlhare-cli)\n'
        self.assertEqual(M.validate_profile(text,123)['state'],'inconclusive')

    def test_spawn_sampler_then_exactly_one_wait4(self):
        order=[]
        observer=types.SimpleNamespace(begin_event=lambda:order.append('begin') or 0,
            finish_event=lambda token:order.append(('finish',token)) or dict(id=0,start_ns=0,end_ns=100))
        def spawn(command): order.append(('spawn',command));return 123
        def sampler(command):
            order.append(('sample',command))
            self.assertNotIn('wait4',str(order))
            return dict(returncode=0,stdout=b'',stderr=b'')
        def wait(pid,options):
            order.append(('wait4',pid,options))
            return pid,0,types.SimpleNamespace(ru_utime=.01,ru_stime=.02,ru_maxrss=100)
        clock=iter((100,200)).__next__
        result=M.measure_once(['/sandbox','cli'],observer,spawn=spawn,sampler=sampler,wait=wait,clock=clock)
        self.assertEqual([r if type(r) is str else r[0] for r in order],['begin','spawn','sample','wait4','finish'])
        self.assertEqual(order[2][1],['/usr/bin/sample','123','1','1','-mayDie','-file',(M.RUN/'sample.txt').as_posix()])
        self.assertEqual(result['timing_label'],M.TIMING_LABEL)
        self.assertEqual(result['metric']['elapsed_ns'],100)

    def test_sampler_failure_leaves_cli_unreaped_for_outer_supervisor(self):
        waited=[]
        observer=types.SimpleNamespace(begin_event=lambda:0,finish_event=lambda _:None)
        with self.assertRaises(M.Refusal):
            M.measure_once(['cli'],observer,spawn=lambda _:123,
                sampler=lambda _:dict(returncode=1,stdout=b'',stderr=b'fail'),
                wait=lambda *a:waited.append(a),clock=lambda:1)
        self.assertEqual(waited,[])

    def test_sampler_stdout_stderr_and_returncode_are_bounded(self):
        M.validate_sampler(dict(returncode=0,stdout=b'',stderr=b''))
        for field,value in [('returncode',True),('returncode',1),('stdout',b'x'*16385),
                            ('stderr',b'x'*16385),('stdout','text')]:
            row=dict(returncode=0,stdout=b'',stderr=b'');row[field]=value
            with self.assertRaises(M.Refusal):M.validate_sampler(row)

    def test_quota_includes_reserved_journal(self):
        value=M.quota_counts(1,1)
        self.assertEqual(value['charged_bytes'],1+131072)
        self.assertEqual(value['charged_entries'],5)
        for size,count in [(8*1024**2,1),(1,64),(-1,1),(True,1)]:
            with self.assertRaises(M.Refusal):M.quota_counts(size,count)

    def test_observer_fixed_eight_captures_and_one_event(self):
        report=dict(schema=1,cadence_ns=1250000000,max_captures=8,completed=True,failure=None,
                    captures=[],events=[dict(id=0,start_ns=4000000000,end_ns=5000000000)])
        for i in range(8):
            report['captures'].append(dict(id=i,target_ns=i*1250000000,start_ns=i*1250000000,
                end_ns=i*1250000000+1000000,environment=dict(schema=1,cpu_ticks=[i*10,i*5,i*85,0],
                logical_cpus=14,thermal_state=0,ac_power=True)))
        M.validate_observation(report)
        report['events'].append(dict(id=1,start_ns=6000000000,end_ns=6000000001))
        with self.assertRaises(M.Refusal):M.validate_observation(report)


if __name__=='__main__':unittest.main()
