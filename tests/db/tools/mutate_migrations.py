#!/usr/bin/env python3
"""Mutation check for migrations: does the SQL test suite notice when the migration is made wrong?

For every mutant (one small text change to a migration) this builds a throwaway database, replays the migrations with the change,
runs the given test files, and reports KILLED (a test failed: good) or SURVIVED (every test still passed: the tests do not
cover that line, or the change does not matter). It never touches a real project: it needs the same scratch Postgres as
tests/db/run.sh (PGHOST/PGPORT/PGUSER) and creates databases named mut_*.

  python3 tests/db/tools/mutate_migrations.py MUTANTS.py [--only 3,7] [--jobs 4]

MUTANTS.py defines   TARGET = '20261014120000'  (the first migration under test; everything before it is the base)
                     TESTS = ['140_desk_orders.sql', ...]      (fast: SQL files from tests/db/tests)
                     SLOW = ['concurrency.sh']                 (optional: shell scripts, run only for mutants every fast test missed)
                     MUTANTS = [(id, 'migration file name', 'exact old text', 'new text'), ...]
The old text must occur exactly once in that migration. Migrations from TARGET on are replayed with the mutation; the baseline
(no mutation) is run first and must pass, otherwise nothing is reported.

Lesson from earlier runs: a run killed halfway leaves nothing behind here (each mutant works on a copy in a temp directory), but
always trust only a run that started with a passing baseline.
"""
import concurrent.futures
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
ENV = dict(os.environ, LC_ALL='C')
BASE_DB = 'mut_base'


def psql(db, *args, check=True, timeout=180):
    cmd = ['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db, *args]
    env = dict(ENV, PGOPTIONS='-c client_min_messages=warning')
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, check=False)


def admin(sql):
    return subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres', '-c', sql],
                          capture_output=True, text=True, env=ENV)


def migrations():
    return sorted(glob.glob(os.path.join(ROOT, 'supabase', 'migrations', '*.sql')), key=lambda p: os.path.basename(p).encode())


def shapes_for(path):
    ts = os.path.basename(path).split('_')[0]
    return sorted(glob.glob(os.path.join(ROOT, 'tests', 'db', 'prod_shapes', ts + '_*.sql')))


def drop_base():
    admin(f'alter database "{BASE_DB}" is_template false')   # a template database cannot be dropped as it is (error ignored when it does not exist)
    admin(f'drop database if exists "{BASE_DB}" with (force)')


def build_base(target):
    drop_base()
    r = admin(f'create database "{BASE_DB}"')
    assert r.returncode == 0, r.stderr
    for f in ('00_supabase_shim.sql', '01_prod_prerequisites.sql'):
        r = psql(BASE_DB, '-f', os.path.join(ROOT, 'tests', 'db', f))
        assert r.returncode == 0, f + ': ' + r.stderr
    for m in migrations():
        if os.path.basename(m).split('_')[0] >= target:
            break
        for s in shapes_for(m):
            r = psql(BASE_DB, '-f', s)
            assert r.returncode == 0, s + ': ' + r.stderr
        r = psql(BASE_DB, '-f', m)
        assert r.returncode == 0, m + ': ' + r.stderr
    for f in ('02_test_helpers.sql', '03_fixtures.sql'):
        r = psql(BASE_DB, '-f', os.path.join(ROOT, 'tests', 'db', f))
        assert r.returncode == 0, f + ': ' + r.stderr
    admin(f'alter database "{BASE_DB}" is_template true')


def run_slow(db, script):
    env = dict(ENV, TEST_DB_NAME=db)
    r = subprocess.run(['bash', os.path.join(ROOT, 'tests', 'db', script)], capture_output=True, text=True, env=env, cwd=ROOT, timeout=300)
    return r


def run_one(name, target, tests, mutation, slow=()):
    """mutation = (migration basename, old, new) or None. Returns 'KILLED', 'SURVIVED', 'INVALID' or 'PASSED' (baseline)."""
    db = 'mut_' + re.sub(r'\W', '_', name)
    admin(f'drop database if exists "{db}" with (force)')
    r = admin(f'create database "{db}" template "{BASE_DB}"')
    if r.returncode != 0:
        return 'INVALID', r.stderr.strip()
    tmp = tempfile.mkdtemp(prefix='mut_')
    try:
        for m in migrations():
            if os.path.basename(m).split('_')[0] < target:
                continue
            for s in shapes_for(m):
                psql(db, '-f', s)
            src = open(m).read()
            if mutation and os.path.basename(m) == mutation[0]:
                src = src.replace(mutation[1], mutation[2], 1)
            f = os.path.join(tmp, os.path.basename(m))
            open(f, 'w').write(src)
            r = psql(db, '-f', f)
            if r.returncode != 0:
                return 'INVALID', (r.stderr.strip().splitlines() or ['?'])[-1][:200]
        for t in tests:
            r = psql(db, '-f', os.path.join(ROOT, 'tests', 'db', 'tests', t))
            if r.returncode != 0:
                msg = [l for l in r.stderr.splitlines() if 'FAIL' in l or 'ERROR' in l]
                return ('FAILED' if mutation is None else 'KILLED', (msg[0] if msg else r.stderr.strip()[:200])[:200])
        for sc in slow:
            r = run_slow(db, sc)
            if r.returncode != 0:
                msg = [l for l in (r.stdout + r.stderr).splitlines() if 'FAIL' in l]
                return ('FAILED' if mutation is None else 'KILLED', (msg[0] if msg else (r.stdout + r.stderr).strip()[-200:])[:200])
        return ('PASSED', '') if mutation is None else ('SURVIVED', '')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        admin(f'drop database if exists "{db}" with (force)')


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    spec = {}
    exec(open(args[0]).read(), spec)
    target, tests, mutants = spec['TARGET'], spec['TESTS'], spec['MUTANTS']
    slow = spec.get('SLOW', [])
    only = None
    jobs = 4
    if '--only' in args:
        only = {int(x) for x in args[args.index('--only') + 1].split(',')}
    if '--jobs' in args:
        jobs = int(args[args.index('--jobs') + 1])

    # Every old text must be found exactly once, or the mutant means nothing.
    texts = {os.path.basename(m): open(m).read() for m in migrations()}
    bad = []
    for (i, mig, old, new) in mutants:
        n = texts.get(mig, '').count(old)
        if n != 1:
            bad.append((i, n, old[:70]))
    if bad:
        for b in bad:
            print(f'mutant {b[0]}: old text found {b[1]} times: {b[2]!r}')
        sys.exit('fix the mutants above (each old text must occur exactly once)')

    print('building the base database ...')
    build_base(target)
    print('baseline (no change) ...')
    status, detail = run_one('baseline', target, tests, None, slow)
    if status != 'PASSED':
        sys.exit(f'the baseline does not pass ({status}), so nothing can be learned: {detail}')

    todo = [m for m in mutants if only is None or m[0] in only]
    survivors, invalid = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run_one, f'm{i}', target, tests, (mig, old, new), slow): (i, mig, old, new) for (i, mig, old, new) in todo}
        for fut in concurrent.futures.as_completed(futs):
            i, mig, old, new = futs[fut]
            status, detail = fut.result()
            if status == 'KILLED':
                print(f'  {i:>3} killed')
            elif status == 'SURVIVED':
                print(f'  {i:>3} SURVIVED  {old[:60]!r} -> {new[:40]!r}')
                survivors.append(i)
            else:
                print(f'  {i:>3} INVALID   {detail}')
                invalid.append(i)
    drop_base()
    print(f'\n{len(todo)} mutants: {len(todo) - len(survivors) - len(invalid)} killed, {len(survivors)} survived {sorted(survivors)}, {len(invalid)} invalid {sorted(invalid)}')
    sys.exit(1 if survivors or invalid else 0)


if __name__ == '__main__':
    main()
