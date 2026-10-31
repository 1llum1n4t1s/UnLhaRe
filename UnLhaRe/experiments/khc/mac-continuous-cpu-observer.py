#!/usr/bin/env python3
"""連続CPU観測の純粋primitive。native取得・signal・子プロセス管理は呼出側の責務。"""
import copy
import threading
import time

CADENCE_NS = 1_250_000_000
MAX_START_LATE_NS = 50_000_000
MAX_CAPTURE_NS = 200_000_000
MIN_WINDOW_NS = 1_000_000_000
MAX_WINDOW_NS = 1_500_000_000


class ObservationError(RuntimeError):
    pass


def validate_environment(value):
    """frozen measure 0867と同じnative環境契約。boolをintとして受理しない。"""
    if (type(value) is not dict or set(value) != {'schema', 'cpu_ticks', 'logical_cpus',
            'thermal_state', 'ac_power'} or type(value['schema']) is not int or value['schema'] != 1
            or type(value['logical_cpus']) is not int or value['logical_cpus'] != 14
            or type(value['thermal_state']) is not int or not 0 <= value['thermal_state'] <= 3
            or type(value['ac_power']) is not bool or type(value['cpu_ticks']) is not list
            or len(value['cpu_ticks']) != 4
            or any(type(n) is not int or not 0 <= n < 2**32 for n in value['cpu_ticks'])):
        raise ObservationError('invalid native environment observation')
    return value


def _integer(value):
    return type(value) is int and value >= 0


def validate_report(report):
    """保存rawのみから窓・coverageを再計算する。返値のeligibleだけが最終合格。

    completed=Falseは実行中snapshot。pendingイベントは追加captureで初めて確定する。
    既知の異常は実行中でもerrorsへ残し、failure後のイベントは全てfailedになる。
    """
    errors, windows, events = [], [], []
    if type(report) is not dict:
        return dict(eligible=False, entry_ready=False, errors=['invalid report'], windows=[], events=[])
    captures = report.get('captures')
    raw_events = report.get('events')
    maximum = report.get('max_captures')
    if (type(report.get('schema')) is not int or report.get('schema') != 1
            or type(report.get('cadence_ns')) is not int or report.get('cadence_ns') != CADENCE_NS
            or type(maximum) is not int or not 4 <= maximum <= 10000
            or type(report.get('completed')) is not bool
            or type(captures) is not list or type(raw_events) is not list):
        return dict(eligible=False, entry_ready=False, errors=['invalid report schema'], windows=[], events=[])
    if report.get('failure') is not None:
        errors.append('observer failed: ' + str(report['failure']))
    if len(captures) > maximum:
        errors.append('capture count exceeds maximum')
    valid = []
    for i, point in enumerate(captures):
        try:
            if type(point) is not dict or set(point) != {'id','target_ns','start_ns','end_ns','environment'}:
                raise ObservationError('capture schema')
            if not all(_integer(point[k]) for k in ('id','target_ns','start_ns','end_ns')):
                raise ObservationError('capture timestamp/id type')
            if point['id'] != i or point['target_ns'] != i * CADENCE_NS:
                raise ObservationError('capture missing/reordered or target changed')
            if not 0 <= point['start_ns'] - point['target_ns'] <= MAX_START_LATE_NS:
                raise ObservationError('capture start late/early')
            if not 0 <= point['end_ns'] - point['start_ns'] <= MAX_CAPTURE_NS:
                raise ObservationError('capture duration/reversal')
            validate_environment(point['environment'])
            if point['environment']['thermal_state'] != 0 or point['environment']['ac_power'] is not True:
                raise ObservationError('thermal/AC condition')
            valid.append(True)
        except (ObservationError, KeyError, TypeError) as exc:
            errors.append('capture %d: %s' % (i, exc))
            valid.append(False)
        if i and valid[i-1] and valid[i]:
            previous = captures[i-1]
            lower = point['start_ns'] - previous['end_ns']
            upper = point['end_ns'] - previous['start_ns']
            delta = [(b-a) % 2**32 for a,b in zip(previous['environment']['cpu_ticks'],
                                                point['environment']['cpu_ticks'])]
            total = sum(delta)
            busy = total - delta[2]
            limit = 15 if i <= 3 else 30
            window = dict(id=i, previous_capture_id=i-1, next_capture_id=i,
                          start_ns=previous['start_ns'], end_ns=point['end_ns'],
                          lower_ns=lower, upper_ns=upper, cpu_tick_deltas=delta,
                          cpu_ticks_total=total, cpu_percent=None if not total else 100*busy/total,
                          cpu_limit_percent=limit)
            windows.append(window)
            if lower < MIN_WINDOW_NS or upper > MAX_WINDOW_NS:
                errors.append('window %d: duration bounds' % i)
            if total == 0:
                errors.append('window %d: Unobservable zero tick interval' % i)
            elif 100 * busy > limit * total:
                errors.append('window %d: CPU limit' % i)
    entry_ready = len(captures) >= 4 and not errors
    for i, event in enumerate(raw_events):
        item = dict(id=i, state='pending', window_ids=[])
        events.append(item)
        if (type(event) is not dict or set(event) != {'id','start_ns','end_ns'}
                or type(event.get('id')) is not int or event['id'] != i
                or not _integer(event.get('start_ns'))
                or (event.get('end_ns') is not None and not _integer(event['end_ns']))):
            errors.append('event %d: schema/sequence' % i)
            item['state']='failed'
            continue
        start, end = event['start_ns'], event['end_ns']
        if len(captures) < 4 or not valid[3] or start < captures[3]['end_ns']:
            errors.append('event %d: started before entry complete' % i)
            item['state']='failed'
        if end is not None:
            if end < start:
                errors.append('event %d: reversed endpoints' % i)
                item['state']='failed'
            item['window_ids'] = [w['id'] for w in windows
                                  if w['start_ns'] <= end and start <= w['end_ns']]
            # active timelineの等号は、未来の窓もinclusiveに交差するため未確定。
            last_bound = captures[-1]['start_ns'] if captures and valid[-1] else None
            full_coverage = (last_bound is not None and (end < last_bound or
                             (report['completed'] and len(captures) == maximum and end == last_bound)))
            if (captures and valid[0] and start >= captures[0]['end_ns']
                    and full_coverage and item['state'] != 'failed'):
                item['state']='covered'
    if report['completed'] and len(captures) != maximum:
        errors.append('completed with missing captures')
    if report['completed'] and any(e['state'] == 'pending' for e in events):
        errors.append('completed without event coverage')
    if errors:
        for event in events:
            event['state']='failed'
    eligible = (report['completed'] and len(captures) == maximum and entry_ready
                and not errors and all(e['state']=='covered' for e in events))
    return dict(eligible=eligible, entry_ready=entry_ready and not errors,
                errors=errors, windows=windows, events=events)


class Observer:
    """固定予定thread。callback遅延も次回遅延として検出し、再同期しない。

    on_failureは必須。呼出側は失敗をbounded保存してfinally os._exit(70)等で
    helperを閉じ、outer supervisorへgroupのkill/reapを委ねる。
    """
    def __init__(self, capture, *, on_failure, on_capture=None, max_captures=10,
                 clock=time.monotonic_ns, sleep=time.sleep):
        if not callable(on_failure) or not callable(capture):
            raise ValueError('capture and on_failure callbacks are required')
        if type(max_captures) is not int or not 4 <= max_captures <= 10000:
            raise ValueError('max_captures must be 4..10000')
        self._capture, self._on_failure, self._on_capture = capture, on_failure, on_capture
        self._clock, self._sleep = clock, sleep
        self._lock = threading.RLock()
        self._condition = threading.Condition(self._lock)
        self._thread = None
        self._epoch_ns = None
        self._report = dict(schema=1, cadence_ns=CADENCE_NS, max_captures=max_captures,
                            captures=[], events=[], failure=None, completed=False)

    @property
    def epoch_ns(self):
        with self._lock:
            return self._epoch_ns

    def _check_failure(self):
        if self._report['failure'] is not None:
            raise ObservationError(self._report['failure'])

    def start(self):
        with self._lock:
            if self._thread is not None:
                raise ObservationError('observer already started')
            self._epoch_ns = self._clock()
            self._thread = threading.Thread(target=self._run, name='continuous-cpu-observer', daemon=True)
            self._thread.start()
        return self

    def _run(self):
        try:
            for i in range(self._report['max_captures']):
                with self._lock:
                    self._check_failure()
                target = i * CADENCE_NS
                remaining = self._epoch_ns + target - self._clock()
                while remaining > 0:
                    self._sleep(remaining / 1_000_000_000)
                    remaining = self._epoch_ns + target - self._clock()
                start = self._clock() - self._epoch_ns
                if not 0 <= start - target <= MAX_START_LATE_NS:
                    raise ObservationError('capture %d: start late/early' % i)
                raw = copy.deepcopy(self._capture())
                end = self._clock() - self._epoch_ns
                record = dict(id=i, target_ns=target, start_ns=start, end_ns=end, environment=raw)
                with self._condition:
                    self._check_failure()
                    self._report['captures'].append(record)
                    check = validate_report(self._report)
                    if check['errors']:
                        raise ObservationError('; '.join(check['errors']))
                if self._on_capture is not None:
                    self._on_capture(copy.deepcopy(record))
                with self._condition:
                    self._condition.notify_all()
            with self._condition:
                self._report['completed'] = True
                check = validate_report(self._report)
                if check['errors']:
                    raise ObservationError('; '.join(check['errors']))
                self._condition.notify_all()
        except BaseException as exc:
            self._fail(exc)

    def _fail(self, exc):
        with self._condition:
            if self._report['failure'] is not None:
                return
            self._report['failure'] = '%s: %s' % (type(exc).__name__, exc)
            self._condition.notify_all()
            partial = copy.deepcopy(self._report['captures'])
        # callback自体の例外もfailureに残す。元の異常を成功へ戻さない。
        try:
            self._on_failure(exc, partial)
        except BaseException as callback_exc:
            with self._condition:
                self._report['failure'] += '; failure callback: %s: %s' % (
                    type(callback_exc).__name__, callback_exc)
                self._condition.notify_all()

    def wait_entry_ready(self, timeout=None):
        with self._condition:
            ready = self._condition.wait_for(lambda: self._report['failure'] is not None
                                            or len(self._report['captures']) >= 4, timeout)
            self._check_failure()
            return ready and validate_report(self._report)['entry_ready']

    def begin_event(self):
        with self._lock:
            self._check_failure()
            if self._report['completed'] or not validate_report(self._report)['entry_ready']:
                raise ObservationError('entry not ready or observer finished')
            token = len(self._report['events'])
            self._report['events'].append(dict(id=token, start_ns=self._clock()-self._epoch_ns, end_ns=None))
            errors = validate_report(self._report)['errors']
        if errors:
            exc = ObservationError('; '.join(errors))
            self._fail(exc)
            raise exc
        return token

    def finish_event(self, token):
        with self._lock:
            self._check_failure()
            if type(token) is not int or not 0 <= token < len(self._report['events']):
                raise ObservationError('unknown event token')
            event = self._report['events'][token]
            if event['end_ns'] is not None:
                raise ObservationError('event already finished')
            event['end_ns'] = self._clock()-self._epoch_ns
            check = validate_report(self._report)
            result = copy.deepcopy(dict(event, **{k:v for k,v in check['events'][token].items() if k!='id'}))
        if check['errors']:
            exc = ObservationError('; '.join(check['errors']))
            self._fail(exc)
            raise exc
        return result

    def join(self, timeout=None):
        if self._thread is None:
            raise ObservationError('observer not started')
        self._thread.join(timeout)
        with self._lock:
            self._check_failure()
            return not self._thread.is_alive()

    def report(self):
        with self._lock:
            raw = copy.deepcopy(self._report)
            raw['epoch_ns'] = self._epoch_ns
            raw['validation'] = validate_report(self._report)
            return raw
